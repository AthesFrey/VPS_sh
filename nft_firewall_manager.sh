#!/usr/bin/env bash

set -e

BACKUP_DIR="${BACKUP_DIR:-/etc/nftables.backup}"
TCP_FILE="${TCP_FILE:-/etc/nft_ports_tcp.list}"
UDP_FILE="${UDP_FILE:-/etc/nft_ports_udp.list}"
MGR_CONF_DIR="${MGR_CONF_DIR:-/etc/nft_firewall_manager}"
MGR_CONF="${MGR_CONF:-$MGR_CONF_DIR/manager.nft}"

MGR_FAMILY="${MGR_FAMILY:-inet}"
MGR_TABLE="${MGR_TABLE:-nft_firewall_manager}"
LOG_PREFIX_NFT="${LOG_PREFIX_NFT:-nft-new: }"
JOURNAL_LIMIT="${JOURNAL_LIMIT:-100M}"
JOURNAL_DROPIN_DIR="${JOURNAL_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_FILE:-$JOURNAL_DROPIN_DIR/99-nft-log-size-limit.conf}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/nft-kernel-logs}"

# Safe default:
#   0 = preserve mode. This script adds/logs allowed ports in its own table,
#       but does not drop unmatched traffic. Existing rules keep deciding drops.
#   1 = strict mode. This script drops unmatched new inbound traffic in its own table.
#       Only enable this after all required ports are in TCP_FILE/UDP_FILE.
STRICT_DROP="${STRICT_DROP:-0}"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] Please run as root."
        exit 1
    fi
}

ensure_nft() {
    if has_cmd nft; then
        return 0
    fi

    echo "[+] nft command not found. Installing nftables..."

    if has_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y nftables
    else
        echo "[ERROR] nftables is not installed and apt-get was not found."
        echo "[ERROR] Please install nftables manually for this OS, then run this script again."
        return 1
    fi
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR" "$MGR_CONF_DIR"
}

ensure_systemctl() {
    if ! has_cmd systemctl; then
        echo "[ERROR] systemctl not found. This function requires systemd."
        return 1
    fi
}

validate_manager_identifiers() {
    case "$MGR_FAMILY" in
        ip|ip6|inet|arp|bridge|netdev)
            ;;
        *)
            echo "[ERROR] Invalid MGR_FAMILY: $MGR_FAMILY"
            echo "[ERROR] Allowed: ip, ip6, inet, arp, bridge, netdev"
            exit 1
            ;;
    esac

    case "$MGR_TABLE" in
        ""|[0-9]*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* )
            echo "[ERROR] Invalid MGR_TABLE: $MGR_TABLE"
            echo "[ERROR] Use a simple nft identifier, for example: nft_firewall_manager"
            exit 1
            ;;
    esac
}

init_files() {
    touch "$TCP_FILE" "$UDP_FILE"

    if [ ! -s "$TCP_FILE" ]; then
        printf "22\n80\n443\n" > "$TCP_FILE"
    fi
}

backup_file() {
    src="$1"
    name="$2"

    if [ -f "$src" ]; then
        cp "$src" "$BACKUP_DIR/$name.$(date +%F-%H%M%S)" || true
    fi
}

backup_active_ruleset() {
    if has_cmd nft; then
        nft list ruleset > "$BACKUP_DIR/active-ruleset.$(date +%F-%H%M%S).nft" 2>/dev/null || true
    fi
}

normalize_text() {
    printf "%s" "$1" \
        | tr '[:space:]' ',' \
        | tr ':' '-' \
        | sed 's/，/,/g; s/,,*/,/g; s/^,//; s/,$//'
}

valid_item() {
    item="$1"

    case "$item" in
        *-*)
            start="${item%-*}"
            end="${item#*-}"

            case "$start$end" in
                *[!0-9]*|"")
                    return 1
                    ;;
            esac

            [ "$start" -ge 1 ] && \
            [ "$start" -le 65535 ] && \
            [ "$end" -ge 1 ] && \
            [ "$end" -le 65535 ] && \
            [ "$start" -le "$end" ]
            ;;
        *)
            case "$item" in
                *[!0-9]*|"")
                    return 1
                    ;;
            esac

            [ "$item" -ge 1 ] && [ "$item" -le 65535 ]
            ;;
    esac
}

csv_from_file() {
    file="$1"

    if [ ! -s "$file" ]; then
        echo ""
        return
    fi

    raw="$(cat "$file")"
    norm="$(normalize_text "$raw")"
    result=""

    OLDIFS="$IFS"
    IFS=','

    for item in $norm; do
        IFS="$OLDIFS"

        [ -n "$item" ] || {
            IFS=','
            continue
        }

        if valid_item "$item"; then
            case ",$result," in
                *,"$item",*)
                    ;;
                *)
                    if [ -z "$result" ]; then
                        result="$item"
                    else
                        result="$result,$item"
                    fi
                    ;;
            esac
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi

        IFS=','
    done

    IFS="$OLDIFS"

    echo "$result"
}

csv_from_text() {
    text="$1"
    tmp="$(mktemp)"

    printf "%s\n" "$text" > "$tmp"
    csv_from_file "$tmp"
    rm -f "$tmp"
}

write_csv_file() {
    file="$1"
    csv="$2"

    : > "$file"

    csv="$(normalize_text "$csv")"

    [ -n "$csv" ] || return

    OLDIFS="$IFS"
    IFS=','

    for item in $csv; do
        IFS="$OLDIFS"

        if valid_item "$item"; then
            echo "$item" >> "$file"
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi

        IFS=','
    done

    IFS="$OLDIFS"
}

nft_set_from_csv() {
    csv="$1"
    printf "%s" "$csv" | sed 's/,/, /g'
}

configure_journal_limit() {
    echo "[+] Configuring journald size limit: $JOURNAL_LIMIT"

    mkdir -p "$JOURNAL_DROPIN_DIR"

    cat > "$JOURNAL_DROPIN_FILE" <<EOF_JOURNAL
[Journal]
SystemMaxUse=$JOURNAL_LIMIT
RuntimeMaxUse=$JOURNAL_LIMIT
SystemMaxFileSize=$JOURNAL_LIMIT
RuntimeMaxFileSize=$JOURNAL_LIMIT
EOF_JOURNAL

    if has_cmd systemctl; then
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    if has_cmd journalctl; then
        journalctl --vacuum-size="$JOURNAL_LIMIT" >/dev/null 2>&1 || true
    fi

    configure_logrotate_limit

    echo "[OK] Log storage limit configured."
}

configure_logrotate_limit() {
    if [ ! -d /etc/logrotate.d ]; then
        return
    fi

    cat > "$LOGROTATE_FILE" <<EOF_LOGROTATE
/var/log/kern.log /var/log/syslog /var/log/messages {
    size $JOURNAL_LIMIT
    rotate 1
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF_LOGROTATE
}

manager_table_exists() {
    nft list table "$MGR_FAMILY" "$MGR_TABLE" >/dev/null 2>&1
}

backup_managed_table() {
    if manager_table_exists; then
        nft list table "$MGR_FAMILY" "$MGR_TABLE" > "$BACKUP_DIR/manager-table.$(date +%F-%H%M%S).nft" 2>/dev/null || true
    fi
}

write_manager_table() {
    out="$1"
    tcp_ports="$(csv_from_file "$TCP_FILE")"
    udp_ports="$(csv_from_file "$UDP_FILE")"
    tcp_set="$(nft_set_from_csv "$tcp_ports")"
    udp_set="$(nft_set_from_csv "$udp_ports")"

    cat >> "$out" <<EOF_NFT
#!/usr/sbin/nft -f

# Generated by nft_firewall_manager_own_table_only_v5.sh
# This file contains only the manager-owned table:
#   $MGR_FAMILY $MGR_TABLE
# Applying this file directly creates/replaces only that table when used by this script.

table $MGR_FAMILY $MGR_TABLE {
    chain input {
        type filter hook input priority 20; policy accept;

        iif "lo" accept comment "nftfw-manager: loopback"
        ct state established,related accept comment "nftfw-manager: established"
        ct state invalid drop comment "nftfw-manager: invalid"
EOF_NFT

    if [ -n "$tcp_ports" ]; then
        echo "        ct state new tcp dport { $tcp_set } log prefix "$LOG_PREFIX_NFT" level info comment "nftfw-manager: log managed tcp"" >> "$out"
        echo "        tcp dport { $tcp_set } accept comment "nftfw-manager: accept managed tcp"" >> "$out"
    fi

    if [ -n "$udp_ports" ]; then
        echo "        ct state new udp dport { $udp_set } log prefix "$LOG_PREFIX_NFT" level info comment "nftfw-manager: log managed udp"" >> "$out"
        echo "        udp dport { $udp_set } accept comment "nftfw-manager: accept managed udp"" >> "$out"
    fi

    if [ "$STRICT_DROP" = "1" ]; then
        cat >> "$out" <<EOF_NFT

        ip protocol icmp accept comment "nftfw-manager: icmp"
        ip6 nexthdr icmpv6 accept comment "nftfw-manager: icmpv6"
        ct state new log prefix "$LOG_PREFIX_NFT" level info comment "nftfw-manager: log unmanaged new"
        counter drop comment "nftfw-manager: strict drop"
EOF_NFT
    else
        cat >> "$out" <<EOF_NFT

        # Preserve mode: do not drop unmatched traffic here.
        # Existing tables/chains keep deciding whether other traffic is allowed or denied.
EOF_NFT
    fi

    cat >> "$out" <<EOF_NFT
    }
}
EOF_NFT
}

build_manager_ruleset() {
    tmp="$1"
    : > "$tmp"
    write_manager_table "$tmp"
}

check_manager_ruleset() {
    manager_tmp="$1"
    check_tmp="$(mktemp)"

    if manager_table_exists; then
        {
            echo "delete table $MGR_FAMILY $MGR_TABLE"
            cat "$manager_tmp"
        } > "$check_tmp"
    else
        cat "$manager_tmp" > "$check_tmp"
    fi

    nft -c -f "$check_tmp"
    rc="$?"
    rm -f "$check_tmp"
    return "$rc"
}

apply_changes() {
    tmp="$(mktemp)"
    old_mgr_tmp="$(mktemp)"
    had_old_mgr=0

    build_manager_ruleset "$tmp"

    echo "[+] Checking manager-only nftables config..."

    if ! check_manager_ruleset "$tmp"; then
        rm -f "$tmp" "$old_mgr_tmp"
        echo "[ERROR] Config check failed. Nothing changed."
        return 1
    fi

    backup_active_ruleset
    backup_managed_table

    if manager_table_exists; then
        had_old_mgr=1
        nft list table "$MGR_FAMILY" "$MGR_TABLE" > "$old_mgr_tmp" 2>/dev/null || : > "$old_mgr_tmp"
        echo "[+] Removing old manager table only: $MGR_FAMILY $MGR_TABLE"
        nft delete table "$MGR_FAMILY" "$MGR_TABLE"
    fi

    mkdir -p "$MGR_CONF_DIR"
    cp "$tmp" "$MGR_CONF"

    configure_journal_limit

    echo "[+] Applying manager table only. No global flush. No nftables restart."

    if nft -f "$tmp"; then
        if has_cmd systemctl; then
            systemctl enable nftables >/dev/null 2>&1 || true
        fi

        rm -f "$tmp" "$old_mgr_tmp"

        echo "[OK] Applied only this manager-owned table: $MGR_FAMILY $MGR_TABLE"
        echo "[OK] Did not run a global flush. Did not rebuild other tables. Did not restart nftables."
        echo "[OK] Manager config saved to: $MGR_CONF"
        if [ "$STRICT_DROP" = "1" ]; then
            echo "[WARN] STRICT_DROP=1 is enabled: unmatched new inbound traffic is dropped by this manager table."
        else
            echo "[OK] Preserve mode is active: unmatched traffic is not dropped by this manager table."
        fi
        echo "[OK] Journal/log size limit target: $JOURNAL_LIMIT"
    else
        echo "[ERROR] Applying manager table failed."
        if [ "$had_old_mgr" -eq 1 ] && [ -s "$old_mgr_tmp" ]; then
            echo "[+] Attempting to restore previous manager table..."
            nft -f "$old_mgr_tmp" || true
        fi
        rm -f "$tmp" "$old_mgr_tmp"
        return 1
    fi
}

start_enable_nftables() {
    ensure_systemctl || return 1

    echo "[INFO] This only enables nftables at boot. It does not start or restart nftables now."
    echo "[INFO] Use Apply changes to update only this manager table in the current running rules."
    echo "[+] Enabling nftables at boot..."
    systemctl enable nftables

    echo "[OK] nftables is enabled at boot. Current active tables were not changed by this option."
    echo ""
    systemctl status nftables --no-pager -l || true
}

stop_disable_nftables() {
    ensure_systemctl || return 1

    echo "[WARN] This option disables nftables at boot only."
    echo "[INFO] It does not stop nftables now and does not flush any active ruleset."
    read -r -p "Type YES to disable nftables at boot only: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    echo "[+] Disabling nftables at boot without stopping it now..."
    systemctl disable nftables

    echo "[OK] nftables is disabled at boot. Current active nft tables were not changed."
    echo ""
    systemctl status nftables --no-pager -l || true
}

show_nftables_active_status() {
    if has_cmd systemctl; then
        active_status="$(systemctl is-active nftables 2>/dev/null || true)"

        case "$active_status" in
            active)
                echo "nftables active: yes"
                ;;
            inactive|failed|activating|deactivating)
                echo "nftables active: no ($active_status)"
                ;;
            *)
                echo "nftables active: unknown"
                ;;
        esac
    else
        echo "nftables active: unknown (systemctl not found)"
    fi

    if [ "$STRICT_DROP" = "1" ]; then
        echo "manager mode: strict drop"
    else
        echo "manager mode: preserve existing rules"
    fi
}

show_ports() {
    echo "=== TCP saved list ==="
    cat "$TCP_FILE" 2>/dev/null || true
    echo ""

    echo "=== TCP effective nft format ==="
    csv_from_file "$TCP_FILE"
    echo ""

    echo "=== UDP saved list ==="
    cat "$UDP_FILE" 2>/dev/null || true
    echo ""

    echo "=== UDP effective nft format ==="
    csv_from_file "$UDP_FILE"
    echo ""

    echo "=== Current active nft dport/log/nat rules ==="
    nft list ruleset 2>/dev/null | grep -E 'dport|log prefix|counter drop|dnat|nftfw-manager' || echo "No active matching rules found"
    echo ""

    echo "=== Journal limit config ==="
    if [ -f "$JOURNAL_DROPIN_FILE" ]; then
        cat "$JOURNAL_DROPIN_FILE"
    else
        echo "No journal limit drop-in found: $JOURNAL_DROPIN_FILE"
    fi
}

extract_active_accept_ports() {
    proto="$1"

    nft list ruleset 2>/dev/null \
        | grep -E "[[:space:]]$proto dport .* accept" \
        | grep -v 'nftfw-manager' \
        | sed -E "s/.*$proto dport[[:space:]]+//" \
        | sed -E 's/[[:space:]]+(counter|accept|log|comment|ct|meta|ip|ip6|iif|oif).*$//' \
        | tr -d '{} ' \
        | tr ',' '\n' \
        | sed '/^$/d' \
        | while read -r item; do
            if valid_item "$item"; then
                echo "$item"
            fi
        done \
        | awk '!seen[$0]++'
}

import_active_accept_ports() {
    active_tcp="$(extract_active_accept_ports tcp | paste -sd, -)"
    active_udp="$(extract_active_accept_ports udp | paste -sd, -)"

    changed=0

    if [ -n "$active_tcp" ]; then
        current_tcp="$(csv_from_file "$TCP_FILE")"
        merged_tcp="$(csv_from_text "$current_tcp,$active_tcp")"
        write_csv_file "$TCP_FILE" "$merged_tcp"
        changed=1
    fi

    if [ -n "$active_udp" ]; then
        current_udp="$(csv_from_file "$UDP_FILE")"
        merged_udp="$(csv_from_text "$current_udp,$active_udp")"
        write_csv_file "$UDP_FILE" "$merged_udp"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        echo "[OK] Imported simple active accept dport rules into saved lists."
    else
        echo "[INFO] No simple active accept dport rules found to import."
    fi

    echo ""
    echo "=== TCP saved list ==="
    cat "$TCP_FILE" 2>/dev/null || true
    echo ""
    echo "=== UDP saved list ==="
    cat "$UDP_FILE" 2>/dev/null || true
}

add_ports() {
    read -r -p "tcp or udp? (t/u): " proto

    case "$proto" in
        t|T)
            file="$TCP_FILE"
            ;;
        u|U)
            file="$UDP_FILE"
            ;;
        *)
            echo "[ERROR] invalid protocol"
            return
            ;;
    esac

    echo "Examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -r -p "port(s): " input

    add_csv="$(csv_from_text "$input")"

    if [ -z "$add_csv" ]; then
        echo "[ERROR] no valid ports found"
        return
    fi

    current_csv="$(csv_from_file "$file")"

    if [ -n "$current_csv" ]; then
        new_csv="$(csv_from_text "$current_csv,$add_csv")"
    else
        new_csv="$add_csv"
    fi

    write_csv_file "$file" "$new_csv"

    echo "[OK] saved ports:"
    cat "$file"

    read -r -p "Apply now? (y/n): " yn

    case "$yn" in
        y|Y)
            apply_changes
            ;;
        *)
            echo "[INFO] saved but not applied yet"
            ;;
    esac
}

remove_ports() {
    read -r -p "tcp or udp? (t/u): " proto

    case "$proto" in
        t|T)
            file="$TCP_FILE"
            ;;
        u|U)
            file="$UDP_FILE"
            ;;
        *)
            echo "[ERROR] invalid protocol"
            return
            ;;
    esac

    echo "Examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -r -p "port(s) to remove: " input

    remove_csv="$(csv_from_text "$input")"
    current_csv="$(csv_from_file "$file")"

    if [ -z "$remove_csv" ]; then
        echo "[ERROR] no valid remove items"
        return
    fi

    if [ -z "$current_csv" ]; then
        echo "[INFO] no saved ports"
        return
    fi

    if [ "$file" = "$TCP_FILE" ]; then
        case ",$remove_csv," in
            *,22,*)
                echo "[WARN] You are removing TCP 22 from this manager list."
                echo "[WARN] Make sure another SSH path is already open and tested."
                read -r -p "Type YES to continue: " confirm

                if [ "$confirm" != "YES" ]; then
                    echo "[INFO] cancelled"
                    return
                fi
                ;;
        esac
    fi

    new_csv=""

    OLDIFS="$IFS"
    IFS=','

    for item in $current_csv; do
        IFS="$OLDIFS"
        skip=0

        IFS=','
        for r in $remove_csv; do
            IFS="$OLDIFS"

            if [ "$item" = "$r" ]; then
                skip=1
            fi

            IFS=','
        done
        IFS="$OLDIFS"

        if [ "$skip" -eq 0 ]; then
            if [ -z "$new_csv" ]; then
                new_csv="$item"
            else
                new_csv="$new_csv,$item"
            fi
        fi

        IFS=','
    done

    IFS="$OLDIFS"

    write_csv_file "$file" "$new_csv"

    echo "[OK] saved ports:"
    cat "$file" 2>/dev/null || true

    read -r -p "Apply now? (y/n): " yn

    case "$yn" in
        y|Y)
            apply_changes
            ;;
        *)
            echo "[INFO] saved but not applied yet"
            ;;
    esac
}

reset_saved_ports() {
    echo "[WARN] This resets saved port lists to:"
    echo "TCP: 22,80,443"
    echo "UDP: empty"
    echo "[WARN] It does not delete existing non-manager nft rules."
    read -r -p "Type YES to reset: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    printf "22\n80\n443\n" > "$TCP_FILE"
    : > "$UDP_FILE"

    echo "[OK] saved port lists reset"
}

show_log_status() {
    echo "=== journald disk usage ==="
    journalctl --disk-usage 2>/dev/null || true
    echo ""

    echo "=== journal limit drop-in ==="
    if [ -f "$JOURNAL_DROPIN_FILE" ]; then
        cat "$JOURNAL_DROPIN_FILE"
    else
        echo "No journal limit drop-in found."
    fi
    echo ""

    echo "=== logrotate fallback ==="
    if [ -f "$LOGROTATE_FILE" ]; then
        cat "$LOGROTATE_FILE"
    else
        echo "No logrotate fallback found."
    fi
}

show_help() {
    cat <<EOF_HELP
Usage:
  bash /root/nft_firewall_manager_own_table_only_v5.sh

Main fix in this version:
  1. Apply changes modifies only this script's own nft table:
       $MGR_FAMILY $MGR_TABLE
  2. It does not run a global ruleset flush.
  3. It does not rebuild other programs' tables from a snapshot.
  4. It does not restart or stop nftables during Apply.
  5. It saves this manager's generated table to:
       $MGR_CONF

Modes:
  Preserve mode, default:
    STRICT_DROP=0
    The manager table does not drop unmatched traffic. Existing rules keep deciding.

  Strict mode, optional and dangerous if your saved lists are incomplete:
    STRICT_DROP=1 bash /root/nft_firewall_manager_own_table_only_v5.sh
    The manager table drops unmatched new inbound traffic.

Important:
  LOG_PREFIX_NFT default is: "nft-new: "
  JOURNAL_LIMIT default is: 100M

Examples:
  JOURNAL_LIMIT=100M bash /root/nft_firewall_manager_own_table_only_v5.sh
  LOG_PREFIX_NFT='nft-new: ' bash /root/nft_firewall_manager_own_table_only_v5.sh
EOF_HELP
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL MANAGER OWN TABLE ONLY v5 ====="
        show_nftables_active_status
        echo "1) Show ports and log rules"
        echo "2) Add port(s)"
        echo "3) Remove port(s)"
        echo "4) Apply changes safely"
        echo "5) Show full nft ruleset"
        echo "6) Import current active accept dport rules into saved lists"
        echo "7) Reset saved port lists"
        echo "8) Configure log size limit only"
        echo "9) Show log size status"
        echo "10) Enable nftables at boot only, no start/restart"
        echo "11) Disable nftables at boot only, no stop/flush"
        echo "12) Help"
        echo "13) Exit"
        echo "======================================"
        read -r -p "Select: " c

        case "$c" in
            1)
                show_ports
                ;;
            2)
                add_ports
                ;;
            3)
                remove_ports
                ;;
            4)
                apply_changes
                ;;
            5)
                nft list ruleset 2>/dev/null || echo "[INFO] No active nft ruleset found, or nft command failed."
                ;;
            6)
                import_active_accept_ports
                ;;
            7)
                reset_saved_ports
                ;;
            8)
                configure_journal_limit
                ;;
            9)
                show_log_status
                ;;
            10)
                start_enable_nftables
                ;;
            11)
                stop_disable_nftables
                ;;
            12)
                show_help
                ;;
            13)
                exit 0
                ;;
            *)
                echo "invalid"
                ;;
        esac
    done
}

need_root
ensure_nft
validate_manager_identifiers
ensure_dirs
init_files
menu




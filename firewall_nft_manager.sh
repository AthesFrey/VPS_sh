#!/usr/bin/env bash

# Unified nftables firewall manager script.
# Unified nftables firewall manager for VPS use.
# Default target: one persistent config file and one nft table:
#   /etc/nftables.conf -> table inet filter
#
# Main design:
# - Normal Apply writes /etc/nftables.conf and reloads nftables directly with nft -f.
# - Normal Apply does NOT use `flush ruleset`; it replaces only the managed table.
# - Emergency Initialize still uses `flush ruleset` to recover to a clean baseline.
# - Port lists are stored in /etc/nft_ports_tcp.list and /etc/nft_ports_udp.list.
# - Emergency Initialize resets TCP to 22,80,443 and UDP to empty.

set -e

SCRIPT_PATH="${0:-nft_firewall_manager.sh}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
if [ -z "$SCRIPT_NAME" ]; then
    SCRIPT_NAME="nft_firewall_manager.sh"
fi

BACKUP_DIR="${BACKUP_DIR:-/etc/nftables.backup}"
TCP_FILE="${TCP_FILE:-/etc/nft_ports_tcp.list}"
UDP_FILE="${UDP_FILE:-/etc/nft_ports_udp.list}"
NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"

# This version intentionally supports only one nft family/table by default.
# Keeping these configurable is mostly for advanced users, but validation below
# restricts them to the safe unified target unless ALLOW_CUSTOM_TARGET=1.
MGR_FAMILY="${MGR_FAMILY:-inet}"
MGR_TABLE="${MGR_TABLE:-filter}"
ALLOW_CUSTOM_TARGET="${ALLOW_CUSTOM_TARGET:-0}"

LOG_PREFIX_NFT="${LOG_PREFIX_NFT:-nft-new: }"
JOURNAL_LIMIT="${JOURNAL_LIMIT:-100M}"
JOURNAL_DROPIN_DIR="${JOURNAL_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_FILE:-$JOURNAL_DROPIN_DIR/99-nft-log-size-limit.conf}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/nft-kernel-logs}"
NFT_BIN="${NFT_BIN:-$(command -v nft 2>/dev/null || echo /usr/sbin/nft)}"

# Docker compatibility: Emergency Initialize uses `flush ruleset`.
# That can remove Docker's iptables-nft/NAT chains.
# auto = after Emergency Initialize only, restart docker.service when it is already active.
# Set to 0/off/no/false to disable, or 1/on/yes/true to force when docker exists.
RESTART_DOCKER_AFTER_NFT="${RESTART_DOCKER_AFTER_NFT:-auto}"

# Normal Apply replaces only the managed nft table and preserves foreign tables.
# Emergency Initialize uses full `flush ruleset` and may remove foreign tables.
# Set SKIP_FOREIGN_TABLE_CONFIRM=1 only if you know Emergency Initialize should proceed.
SKIP_FOREIGN_TABLE_CONFIRM="${SKIP_FOREIGN_TABLE_CONFIRM:-0}"

# Log storage limits are not changed during Apply by default.
AUTO_CONFIGURE_LOG_LIMIT="${AUTO_CONFIGURE_LOG_LIMIT:-0}"

# Safety default for generated input chain. Keep this enabled for a firewall.
INPUT_POLICY_DROP="${INPUT_POLICY_DROP:-1}"

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
        NFT_BIN="$(command -v nft)"
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

    if has_cmd nft; then
        NFT_BIN="$(command -v nft)"
        return 0
    fi

    echo "[ERROR] nft was still not found after installation attempt."
    return 1
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR"
}

ensure_systemctl() {
    if ! has_cmd systemctl; then
        echo "[ERROR] systemctl not found. This function requires systemd."
        return 1
    fi
}

docker_service_active() {
    has_cmd systemctl && systemctl is-active --quiet docker 2>/dev/null
}

docker_unit_exists() {
    has_cmd systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1
}

maybe_restart_docker_after_nft() {
    mode="$RESTART_DOCKER_AFTER_NFT"

    case "$mode" in
        0|no|NO|false|FALSE|off|OFF)
            return 0
            ;;
        auto|AUTO|"")
            if ! docker_service_active; then
                return 0
            fi
            ;;
        1|yes|YES|true|TRUE|on|ON)
            if ! docker_unit_exists; then
                return 0
            fi
            ;;
        *)
            echo "[WARN] Unknown RESTART_DOCKER_AFTER_NFT=$mode; skipping Docker restart."
            return 0
            ;;
    esac

    echo "[INFO] Restarting docker.service to rebuild Docker NAT/DOCKER chains after nftables reload..."
    if systemctl restart docker; then
        echo "[OK] docker.service restarted."
    else
        echo "[WARN] docker.service restart failed. If Docker port publishing fails, run: systemctl restart docker"
    fi
}

validate_identifier() {
    name="$1"
    value="$2"

    case "$value" in
        ""|[0-9]*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* )
            echo "[ERROR] Invalid $name: $value"
            echo "[ERROR] Use a simple nft identifier, for example: filter"
            exit 1
            ;;
    esac
}

validate_manager_target() {
    validate_identifier "MGR_TABLE" "$MGR_TABLE"

    case "$MGR_FAMILY" in
        inet)
            ;;
        *)
            echo "[ERROR] This unified version supports only MGR_FAMILY=inet by default."
            echo "[ERROR] Current MGR_FAMILY: $MGR_FAMILY"
            echo "[ERROR] Reason: the generated config contains both IPv4 and IPv6 rules in one table."
            echo "[ERROR] Use MGR_FAMILY=inet, or set ALLOW_CUSTOM_TARGET=1 only after reviewing the generated nft config."
            if [ "$ALLOW_CUSTOM_TARGET" != "1" ]; then
                exit 1
            fi
            ;;
    esac

    if [ "$MGR_TABLE" != "filter" ] && [ "$ALLOW_CUSTOM_TARGET" != "1" ]; then
        echo "[ERROR] This unified version manages table inet filter by default."
        echo "[ERROR] Current MGR_TABLE: $MGR_TABLE"
        echo "[ERROR] Set ALLOW_CUSTOM_TARGET=1 only if you intentionally want another table name."
        exit 1
    fi
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

backup_persistent_files() {
    backup_file "$NFT_CONF" "nftables.conf"
    backup_file "$TCP_FILE" "nft_ports_tcp.list"
    backup_file "$UDP_FILE" "nft_ports_udp.list"
}

nft_escape_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
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
        *-*-*|"" )
            return 1
            ;;
        *-*)
            start="${item%-*}"
            end="${item#*-}"

            case "$start" in
                ""|*[!0-9]* )
                    return 1
                    ;;
            esac

            case "$end" in
                ""|*[!0-9]* )
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
                *[!0-9]*|"" )
                    return 1
                    ;;
            esac

            [ "$item" -ge 1 ] && [ "$item" -le 65535 ]
            ;;
    esac
}

item_start() {
    item="$1"
    case "$item" in
        *-*)
            printf '%s\n' "${item%-*}"
            ;;
        *)
            printf '%s\n' "$item"
            ;;
    esac
}

item_end() {
    item="$1"
    case "$item" in
        *-*)
            printf '%s\n' "${item#*-}"
            ;;
        *)
            printf '%s\n' "$item"
            ;;
    esac
}

csv_canonicalize() {
    csv="$1"
    tmp_items="$(mktemp)"
    tmp_sorted="$(mktemp)"

    csv="$(normalize_text "$csv")"

    if [ -z "$csv" ]; then
        rm -f "$tmp_items" "$tmp_sorted"
        echo ""
        return
    fi

    OLDIFS="$IFS"
    IFS=','

    for item in $csv; do
        IFS="$OLDIFS"

        [ -n "$item" ] || {
            IFS=','
            continue
        }

        if valid_item "$item"; then
            printf '%s %s\n' "$(item_start "$item")" "$(item_end "$item")" >> "$tmp_items"
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi

        IFS=','
    done

    IFS="$OLDIFS"

    if [ ! -s "$tmp_items" ]; then
        rm -f "$tmp_items" "$tmp_sorted"
        echo ""
        return
    fi

    sort -n -k1,1 -k2,2 "$tmp_items" > "$tmp_sorted"

    awk '
        function emit(s, e) {
            if (s == "") {
                return
            }
            if (s == e) {
                out = s
            } else {
                out = s "-" e
            }
            if (result == "") {
                result = out
            } else {
                result = result "," out
            }
        }
        {
            s = $1 + 0
            e = $2 + 0
            if (NR == 1) {
                cur_s = s
                cur_e = e
                next
            }
            if (s <= cur_e + 1) {
                if (e > cur_e) {
                    cur_e = e
                }
            } else {
                emit(cur_s, cur_e)
                cur_s = s
                cur_e = e
            }
        }
        END {
            if (NR > 0) {
                emit(cur_s, cur_e)
            }
            print result
        }
    ' "$tmp_sorted"

    rm -f "$tmp_items" "$tmp_sorted"
}

csv_from_file() {
    file="$1"

    if [ ! -s "$file" ]; then
        echo ""
        return
    fi

    csv_canonicalize "$(cat "$file")"
}

csv_from_text() {
    text="$1"
    csv_canonicalize "$text"
}

write_csv_file() {
    file="$1"
    csv="$2"

    : > "$file"

    csv="$(csv_canonicalize "$csv")"

    [ -n "$csv" ] || return

    OLDIFS="$IFS"
    IFS=','

    for item in $csv; do
        IFS="$OLDIFS"
        echo "$item" >> "$file"
        IFS=','
    done

    IFS="$OLDIFS"
}

nft_set_from_csv() {
    csv="$1"
    printf "%s" "$csv" | sed 's/,/, /g'
}

csv_contains_port() {
    csv="$1"
    port="$2"

    csv="$(csv_canonicalize "$csv")"
    [ -n "$csv" ] || return 1

    OLDIFS="$IFS"
    IFS=','

    for item in $csv; do
        IFS="$OLDIFS"
        s="$(item_start "$item")"
        e="$(item_end "$item")"
        if [ "$port" -ge "$s" ] && [ "$port" -le "$e" ]; then
            IFS="$OLDIFS"
            return 0
        fi
        IFS=','
    done

    IFS="$OLDIFS"
    return 1
}

csv_subtract() {
    current_csv="$(csv_canonicalize "$1")"
    remove_csv="$(csv_canonicalize "$2")"

    if [ -z "$current_csv" ]; then
        echo ""
        return
    fi

    if [ -z "$remove_csv" ]; then
        echo "$current_csv"
        return
    fi

    awk -v current="$current_csv" -v remove="$remove_csv" '
        function parse_range(item, arr) {
            n = split(item, parts, "-")
            arr[1] = parts[1] + 0
            if (n == 1) {
                arr[2] = parts[1] + 0
            } else {
                arr[2] = parts[2] + 0
            }
        }
        function emit(s, e) {
            if (s > e) {
                return
            }
            if (s == e) {
                out = s
            } else {
                out = s "-" e
            }
            if (result == "") {
                result = out
            } else {
                result = result "," out
            }
        }
        BEGIN {
            seg_count = 0
            curr_count = split(current, curr_items, ",")
            for (i = 1; i <= curr_count; i++) {
                parse_range(curr_items[i], r)
                seg_count++
                seg_s[seg_count] = r[1]
                seg_e[seg_count] = r[2]
            }

            rem_count = split(remove, rem_items, ",")
            for (ri = 1; ri <= rem_count; ri++) {
                parse_range(rem_items[ri], rr)
                rs = rr[1]
                re = rr[2]
                new_count = 0
                delete new_s
                delete new_e

                for (si = 1; si <= seg_count; si++) {
                    ss = seg_s[si]
                    se = seg_e[si]

                    if (re < ss || rs > se) {
                        new_count++
                        new_s[new_count] = ss
                        new_e[new_count] = se
                    } else {
                        if (ss < rs) {
                            new_count++
                            new_s[new_count] = ss
                            new_e[new_count] = rs - 1
                        }
                        if (re < se) {
                            new_count++
                            new_s[new_count] = re + 1
                            new_e[new_count] = se
                        }
                    }
                }

                seg_count = new_count
                delete seg_s
                delete seg_e
                for (si = 1; si <= seg_count; si++) {
                    seg_s[si] = new_s[si]
                    seg_e[si] = new_e[si]
                }
            }

            for (si = 1; si <= seg_count; si++) {
                emit(seg_s[si], seg_e[si])
            }
            print result
        }
    '
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

foreign_tables() {
    if ! has_cmd nft; then
        return 0
    fi

    nft list tables 2>/dev/null \
        | awk -v family="$MGR_FAMILY" -v table="$MGR_TABLE" '
            $1 == "table" {
                if (!($2 == family && $3 == table)) {
                    print $0
                }
            }
        '
}

show_foreign_tables_warning() {
    foreign="$(foreign_tables || true)"
    if [ -n "$foreign" ]; then
        echo "[WARN] Active nftables contains tables outside $MGR_FAMILY $MGR_TABLE:"
        printf '%s\n' "$foreign"
        echo "[WARN] Emergency Initialize uses 'flush ruleset'."
        echo "[WARN] It will remove those active foreign tables, including iptables-nft tables."
        return 0
    fi
    return 1
}

confirm_if_foreign_tables_exist() {
    if [ "$SKIP_FOREIGN_TABLE_CONFIRM" = "1" ]; then
        return 0
    fi

    if show_foreign_tables_warning; then
        echo "[WARN] Continue only if you want one clean nftables ruleset."
        read -r -p "Type YES to continue: " confirm
        if [ "$confirm" != "YES" ]; then
            echo "[INFO] cancelled"
            return 1
        fi
    fi

    return 0
}

write_unified_nft_conf() {
    out="$1"
    mode="${2:-table_only}"
    tcp_ports="$(csv_from_file "$TCP_FILE")"
    udp_ports="$(csv_from_file "$UDP_FILE")"
    tcp_set="$(nft_set_from_csv "$tcp_ports")"
    udp_set="$(nft_set_from_csv "$udp_ports")"
    log_prefix_escaped="$(nft_escape_string "$LOG_PREFIX_NFT")"

    input_policy="accept"
    if [ "$INPUT_POLICY_DROP" = "1" ]; then
        input_policy="drop"
    fi

    cat > "$out" <<EOF_NFT
#!/usr/sbin/nft -f

# Generated by $SCRIPT_NAME
# Config file: $NFT_CONF
# Managed table: $MGR_FAMILY $MGR_TABLE
EOF_NFT

    case "$mode" in
        full_flush)
            cat >> "$out" <<EOF_NFT
# Mode: Emergency Initialize. This intentionally flushes the full ruleset.
# It removes foreign/iptables-nft generated tables, including Docker NAT chains.

flush ruleset

EOF_NFT
            ;;
        table_only|"")
            cat >> "$out" <<EOF_NFT
# Mode: Normal Apply. This preserves foreign tables and replaces only the managed table.
# It avoids global 'flush ruleset' so Docker/NAT/port-jump tables are not cleared.

# Delete the managed table if it already exists; do nothing if it does not exist.
# Requires a reasonably modern nftables with 'destroy' support.
destroy table $MGR_FAMILY $MGR_TABLE

EOF_NFT
            ;;
        *)
            echo "[ERROR] Invalid nft config mode: $mode" >&2
            return 1
            ;;
    esac

    cat >> "$out" <<EOF_NFT
table $MGR_FAMILY $MGR_TABLE {
    chain input {
        type filter hook input priority 0; policy $input_policy;

        iif "lo" accept comment "nftfw: loopback"
        ct state established,related accept comment "nftfw: established related"
        ct state invalid drop comment "nftfw: invalid"
EOF_NFT

    if [ -n "$tcp_ports" ]; then
        printf '\n        ct state new tcp dport { %s } log prefix "%s" level info comment "nftfw: log managed tcp"\n' "$tcp_set" "$log_prefix_escaped" >> "$out"
        printf '        tcp dport { %s } accept comment "nftfw: accept managed tcp"\n' "$tcp_set" >> "$out"
    fi

    if [ -n "$udp_ports" ]; then
        printf '\n        ct state new udp dport { %s } log prefix "%s" level info comment "nftfw: log managed udp"\n' "$udp_set" "$log_prefix_escaped" >> "$out"
        printf '        udp dport { %s } accept comment "nftfw: accept managed udp"\n' "$udp_set" >> "$out"
    fi

    cat >> "$out" <<EOF_NFT

        ip protocol icmp accept comment "nftfw: icmp"
        ip6 nexthdr icmpv6 accept comment "nftfw: icmpv6"

        ct state new log prefix "$log_prefix_escaped" level info comment "nftfw: log unmanaged new"
        counter drop comment "nftfw: final input drop"
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        counter drop comment "nftfw: forward drop"
    }

    chain output {
        type filter hook output priority 0; policy accept;
        accept comment "nftfw: output accept"
    }
}
EOF_NFT
}

build_unified_config() {
    tmp="$1"
    mode="${2:-table_only}"
    write_unified_nft_conf "$tmp" "$mode"
}

check_nft_config() {
    tmp="$1"
    nft -c -f "$tmp"
}

apply_config_file() {
    tmp="$1"
    action_name="$2"
    uses_full_flush="${3:-0}"
    backup_conf="$(mktemp)"
    had_old_conf=0

    echo "[+] Checking nftables config syntax..."
    if ! check_nft_config "$tmp"; then
        rm -f "$backup_conf"
        echo "[ERROR] Config check failed. Nothing changed."
        if grep -q '^destroy table ' "$tmp" 2>/dev/null; then
            echo "[HINT] Normal Apply uses 'destroy table' to replace only the managed table."
            echo "[HINT] If your nftables is too old for this syntax, upgrade nftables before applying."
        fi
        return 1
    fi

    if [ "$uses_full_flush" = "1" ]; then
        confirm_if_foreign_tables_exist || {
            rm -f "$backup_conf"
            return 1
        }
    fi

    backup_active_ruleset
    backup_persistent_files

    if [ -f "$NFT_CONF" ]; then
        had_old_conf=1
        cp "$NFT_CONF" "$backup_conf"
    fi

    echo "[+] Writing nftables config: $NFT_CONF"
    cp "$tmp" "$NFT_CONF"

    if [ "$AUTO_CONFIGURE_LOG_LIMIT" = "1" ]; then
        configure_journal_limit
    else
        echo "[INFO] Skipping journal/logrotate changes. Use menu 9 if needed."
    fi

    echo "[+] Loading nftables directly with nft -f..."
    echo "[INFO] Not using 'systemctl restart nftables' here, because some nftables.service units run 'flush ruleset' on stop."
    if nft -f "$NFT_CONF"; then
        if has_cmd systemctl; then
            systemctl enable nftables >/dev/null 2>&1 || true
        fi
        if [ "$uses_full_flush" = "1" ]; then
            maybe_restart_docker_after_nft
        fi
        echo "[OK] $action_name completed. Active rules now come from: $NFT_CONF"
        rm -f "$backup_conf"
        return 0
    fi

    echo "[ERROR] nft -f failed. Attempting rollback..."
    if [ "$had_old_conf" -eq 1 ]; then
        cp "$backup_conf" "$NFT_CONF"
        nft -f "$NFT_CONF" || true
    fi
    rm -f "$backup_conf"
    return 1
}

apply_changes() {
    tmp="$(mktemp)"
    build_unified_config "$tmp" "table_only"

    echo "[+] Applying managed nftables table only: $MGR_FAMILY $MGR_TABLE"
    echo "[INFO] Normal Apply preserves foreign tables and does not use global flush ruleset."
    if apply_config_file "$tmp" "Apply" "0"; then
        rm -f "$tmp"
        echo "[OK] Managed TCP ports: $(csv_from_file "$TCP_FILE")"
        echo "[OK] Managed UDP ports: $(csv_from_file "$UDP_FILE")"
        echo "[OK] Note: Normal Apply replaced only the managed table and preserved foreign tables."
        return 0
    fi

    rm -f "$tmp"
    return 1
}

reset_port_files_to_safe_defaults() {
    printf "22\n80\n443\n" > "$TCP_FILE"
    : > "$UDP_FILE"
}

initialize_nft_safe() {
    echo "[WARN] Emergency Initialize will reset the firewall to a clean single-table config:"
    echo "[WARN]   Config: $NFT_CONF"
    echo "[WARN]   Table:  $MGR_FAMILY $MGR_TABLE"
    echo "[WARN]   TCP allowed: 22,80,443"
    echo "[WARN]   UDP allowed: none"
    echo "[WARN]   Forward: drop"
    echo "[WARN]   Output: accept"
    echo "[WARN] It uses 'flush ruleset' and removes active foreign tables."
    read -r -p "Type YES to initialize/recover nftables now: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    backup_active_ruleset
    backup_persistent_files
    reset_port_files_to_safe_defaults

    tmp="$(mktemp)"
    build_unified_config "$tmp" "full_flush"

    if apply_config_file "$tmp" "Emergency initialize" "1"; then
        rm -f "$tmp"
        echo "[OK] Safe baseline is active: TCP 22,80,443 only; UDP empty."
        return 0
    fi

    rm -f "$tmp"
    return 1
}

reset_saved_ports() {
    echo "[WARN] This resets saved port lists only:"
    echo "TCP: 22,80,443"
    echo "UDP: empty"
    echo "[WARN] It does not apply/restart nftables until you choose Apply."
    read -r -p "Type YES to reset saved lists: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    backup_persistent_files
    reset_port_files_to_safe_defaults

    echo "[OK] saved port lists reset"
}

show_nftables_active_status() {
    if has_cmd systemctl; then
        active_status="$(systemctl is-active nftables 2>/dev/null || true)"
        enabled_status="$(systemctl is-enabled nftables 2>/dev/null || true)"

        echo "nftables active: ${active_status:-unknown}"
        echo "nftables enabled: ${enabled_status:-unknown}"
    else
        echo "nftables active: unknown (systemctl not found)"
    fi

    echo "target config: $NFT_CONF"
    echo "target table: $MGR_FAMILY $MGR_TABLE"
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

    echo "=== Active unified table ==="
    nft list table "$MGR_FAMILY" "$MGR_TABLE" 2>/dev/null || echo "No active target table found: $MGR_FAMILY $MGR_TABLE"
    echo ""

    echo "=== Foreign active tables ==="
    foreign_tables 2>/dev/null || true
    echo ""

    echo "=== Global dport/log/nat rules for reference only ==="
    nft list ruleset 2>/dev/null | grep -E 'dport|log prefix|counter drop|dnat|nftfw|nft-new' || echo "No active matching rules found"
    echo ""

    echo "=== Current persistent config path ==="
    echo "$NFT_CONF"
}

show_generated_config() {
    tmp="$(mktemp)"
    build_unified_config "$tmp" "table_only"
    echo "=== Generated normal Apply config preview ==="
    cat "$tmp"
    rm -f "$tmp"
}

extract_active_accept_ports() {
    proto="$1"

    nft list ruleset 2>/dev/null \
        | grep -E "[[:space:]]$proto dport .* accept" \
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
            label="TCP"
            ;;
        u|U)
            file="$UDP_FILE"
            label="UDP"
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

    echo "[OK] saved $label ports:"
    cat "$file"

    read -r -p "Apply now? This rewrites $NFT_CONF and reloads only the managed nft table. (y/n): " yn

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
            label="TCP"
            ;;
        u|U)
            file="$UDP_FILE"
            label="UDP"
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

    if [ "$file" = "$TCP_FILE" ] && csv_contains_port "$remove_csv" 22; then
        echo "[WARN] You are removing or partially removing TCP 22 from this firewall list."
        echo "[WARN] Make sure another SSH path is already open and tested."
        read -r -p "Type YES to continue: " confirm

        if [ "$confirm" != "YES" ]; then
            echo "[INFO] cancelled"
            return
        fi
    fi

    new_csv="$(csv_subtract "$current_csv" "$remove_csv")"
    write_csv_file "$file" "$new_csv"

    echo "[OK] saved $label ports after range-aware removal:"
    cat "$file" 2>/dev/null || true

    read -r -p "Apply now? This rewrites $NFT_CONF and reloads only the managed nft table. (y/n): " yn

    case "$yn" in
        y|Y)
            apply_changes
            ;;
        *)
            echo "[INFO] saved but not applied yet"
            ;;
    esac
}

configure_nftables_boot() {
    ensure_systemctl || return 1

    echo "[+] Enabling nftables service at boot..."
    systemctl enable nftables
    echo "[OK] nftables service enabled. It will load: $NFT_CONF"
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
  bash $SCRIPT_PATH

Main behavior in this version:
  1. Manages one persistent nftables config file:
       $NFT_CONF
  2. Manages one nft table:
       $MGR_FAMILY $MGR_TABLE
  3. Normal Apply does NOT use global flush ruleset. It uses:
       destroy table $MGR_FAMILY $MGR_TABLE
     then rebuilds only that managed table. Foreign tables created by Docker,
     iptables-nft, sing-box NAT, DNAT, etc. are preserved.
  4. Emergency Initialize still uses:
       flush ruleset
     to recover to one clean baseline ruleset.
  5. Input chain default is drop, with explicit allow rules for saved TCP/UDP ports.
  6. Forward is drop. Output is accept.
  7. Emergency Initialize resets to TCP 22,80,443 and empty UDP.

Why this is different from the old own-table script:
  The old version used a separate manager table with priority 20. Its accept rules
  could fail to override drops in another base chain. This version writes the
  managed main table, so its allow/drop decisions are authoritative inside that
  table, while Normal Apply still preserves foreign nftables tables.

Range-aware removal:
  Removing 1002 from 1000-1005 produces 1000-1001,1003-1005.
  Removing 1002-1003 from 1000-1005 produces 1000-1001,1004-1005.
  Removing a range that includes TCP 22 triggers an SSH warning.

Safe baseline:
  Menu 7 writes the equivalent of:
    TCP: 22,80,443
    UDP: empty
    table inet filter with input drop, forward drop, output accept

Important caution:
  Normal Apply preserves foreign nftables tables, but it still replaces the whole
  managed table: $MGR_FAMILY $MGR_TABLE. Avoid putting unrelated manual rules in
  that same table unless you want this script to own them. Backups are saved under:
    $BACKUP_DIR

Docker compatibility in this build:
  RESTART_DOCKER_AFTER_NFT=$RESTART_DOCKER_AFTER_NFT
  Normal Apply should not disturb Docker NAT chains. Default auto means: after
  Emergency Initialize only, restart docker.service when Docker is already active,
  so Docker can recreate its DOCKER/NAT chains after a full flush.
EOF_HELP
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL MANAGER UNIFIED MAIN TABLE ($SCRIPT_NAME) ====="
        show_nftables_active_status
        echo "1) Show saved ports, active table, and foreign table reference"
        echo "2) Add port(s)"
        echo "3) Remove port(s), range-aware"
        echo "4) Apply saved ports to unified /etc/nftables.conf"
        echo "5) Show full active nft ruleset"
        echo "6) Import current active accept dport rules into saved lists"
        echo "7) Emergency initialize/recover NFT to TCP 22,80,443 only"
        echo "8) Reset saved port lists only, no apply"
        echo "9) Configure log size limit only"
        echo "10) Show log size status"
        echo "11) Enable nftables service at boot"
        echo "12) Preview generated config"
        echo "13) Help"
        echo "14) Exit"
        echo "======================================================="
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
                initialize_nft_safe
                ;;
            8)
                reset_saved_ports
                ;;
            9)
                configure_journal_limit
                ;;
            10)
                show_log_status
                ;;
            11)
                configure_nftables_boot
                ;;
            12)
                show_generated_config
                ;;
            13)
                show_help
                ;;
            14)
                exit 0
                ;;
            *)
                echo "invalid"
                ;;
        esac
    done
}

show_cli_usage() {
    cat <<EOF_USAGE
Usage:
  bash $SCRIPT_PATH
  bash $SCRIPT_PATH --apply
  bash $SCRIPT_PATH --init-safe
  bash $SCRIPT_PATH --show
  bash $SCRIPT_PATH --preview
  bash $SCRIPT_PATH --help

Options:
  --apply       Build $NFT_CONF from saved port lists and reload only the managed table.
  --init-safe   Emergency reset to TCP 22,80,443 and empty UDP, then restart/apply nftables.
  --show        Show saved ports and active table/reference rules.
  --preview     Print the normal Apply config without applying it.
  --help        Show detailed help.

Environment shortcuts:
  SKIP_FOREIGN_TABLE_CONFIRM=1  Do not ask when foreign active nft tables exist.
  AUTO_CONFIGURE_LOG_LIMIT=1    Configure journal/logrotate limits during Apply.
EOF_USAGE
}

main() {
    need_root
    ensure_nft
    validate_manager_target
    ensure_dirs
    init_files

    case "${1:-}" in
        "")
            menu
            ;;
        --apply)
            apply_changes
            ;;
        --init-safe|--initialize|--rescue)
            initialize_nft_safe
            ;;
        --show)
            show_ports
            ;;
        --preview)
            show_generated_config
            ;;
        --help|-h)
            show_cli_usage
            echo ""
            show_help
            ;;
        *)
            echo "[ERROR] unknown option: $1"
            show_cli_usage
            exit 1
            ;;
    esac
}

if [ "${NFTFW_MANAGER_TESTING:-0}" != "1" ]; then
    main "$@"
fi

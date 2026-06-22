#!/usr/bin/env bash

set -e

CONF="${CONF:-/etc/nftables.conf}"
BACKUP_DIR="${BACKUP_DIR:-/etc/nftables.backup}"
TCP_FILE="${TCP_FILE:-/etc/nft_ports_tcp.list}"
UDP_FILE="${UDP_FILE:-/etc/nft_ports_udp.list}"

LOG_PREFIX_NFT="${LOG_PREFIX_NFT:-nft-new: }"
JOURNAL_LIMIT="${JOURNAL_LIMIT:-100M}"
JOURNAL_DROPIN_DIR="${JOURNAL_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_FILE:-$JOURNAL_DROPIN_DIR/99-nft-log-size-limit.conf}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/nft-kernel-logs}"

mkdir -p "$BACKUP_DIR"

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
    if ! has_cmd nft; then
        echo "[+] Installing nftables..."
        apt update -y
        apt install -y nftables
    fi
}

init_files() {
    touch "$TCP_FILE" "$UDP_FILE"

    if [ ! -s "$TCP_FILE" ]; then
        printf "22\n80\n443\n" > "$TCP_FILE"
    fi
}

backup_conf() {
    if [ -f "$CONF" ]; then
        cp "$CONF" "$BACKUP_DIR/nftables.conf.$(date +%F-%H%M%S)" || true
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

build_tmp_ruleset() {
    tmp="$1"

    tcp_ports="$(csv_from_file "$TCP_FILE")"
    udp_ports="$(csv_from_file "$UDP_FILE")"

    cat > "$tmp" <<EOF_NFT
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

EOF_NFT

    if [ -n "$tcp_ports" ]; then
        echo "        ct state new tcp dport {$tcp_ports} log prefix \"$LOG_PREFIX_NFT\" level info" >> "$tmp"
        echo "        tcp dport {$tcp_ports} accept" >> "$tmp"
    fi

    if [ -n "$udp_ports" ]; then
        echo "        ct state new udp dport {$udp_ports} log prefix \"$LOG_PREFIX_NFT\" level info" >> "$tmp"
        echo "        udp dport {$udp_ports} accept" >> "$tmp"
    fi

    cat >> "$tmp" <<EOF_NFT

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        ct state new log prefix "$LOG_PREFIX_NFT" level info
        counter drop
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
        accept
    }
}
EOF_NFT
}

apply_changes() {
    tmp="$(mktemp)"

    build_tmp_ruleset "$tmp"

    echo "[+] Checking nftables config..."

    if nft -c -f "$tmp"; then
        backup_conf
        cp "$tmp" "$CONF"
        configure_journal_limit
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl restart nftables
        rm -f "$tmp"

        echo "[OK] nftables applied safely"
        echo "[OK] Allowed TCP/UDP ports are logged before accept."
        echo "[OK] Other new connections are logged before drop."
        echo "[OK] Journal/log size limit target: $JOURNAL_LIMIT"
    else
        rm -f "$tmp"
        echo "[ERROR] Config check failed. Nothing changed."
        return 1
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

    echo "=== Current active nft dport/log rules ==="
    nft list ruleset 2>/dev/null | grep -E 'ct state new|dport|log prefix|counter drop' || echo "No active matching rules found"
    echo ""

    echo "=== Journal limit config ==="
    if [ -f "$JOURNAL_DROPIN_FILE" ]; then
        cat "$JOURNAL_DROPIN_FILE"
    else
        echo "No journal limit drop-in found: $JOURNAL_DROPIN_FILE"
    fi
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
                echo "[WARN] You are removing TCP 22."
                echo "[WARN] Make sure another SSH port is already open and tested."
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
  bash /root/nft_firewall_manager_final.sh

What this final version does:
  1. Logs allowed TCP new connections before accept.
  2. Logs allowed UDP new connections before accept.
  3. Logs other new connections before drop.
  4. Keeps established/related traffic accepted without logging every packet.
  5. Configures journald total log storage target to $JOURNAL_LIMIT.
  6. Adds a logrotate fallback for common text logs: kern.log, syslog, messages.

Important:
  LOG_PREFIX_NFT default is: "nft-new: "
  JOURNAL_LIMIT default is: 100M

Examples:
  JOURNAL_LIMIT=100M bash /root/nft_firewall_manager_final.sh
  LOG_PREFIX_NFT='nft-new: ' bash /root/nft_firewall_manager_final.sh
EOF_HELP
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL MANAGER FINAL ====="
        echo "1) Show ports and log rules"
        echo "2) Add port(s)"
        echo "3) Remove port(s)"
        echo "4) Apply changes"
        echo "5) Show full nft ruleset"
        echo "6) Reset saved port lists"
        echo "7) Configure log size limit only"
        echo "8) Show log size status"
        echo "9) Help"
        echo "10) Exit"
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
                nft list ruleset
                ;;
            6)
                reset_saved_ports
                ;;
            7)
                configure_journal_limit
                ;;
            8)
                show_log_status
                ;;
            9)
                show_help
                ;;
            10)
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
init_files
menu

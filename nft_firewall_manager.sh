cat > /root/nft_firewall_manager.sh <<'EOF'
#!/usr/bin/env bash

set -e

CONF="/etc/nftables.conf"
BACKUP_DIR="/etc/nftables.backup"
TCP_FILE="/etc/nft_ports_tcp.list"
UDP_FILE="/etc/nft_ports_udp.list"

mkdir -p "$BACKUP_DIR"

ensure_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "[+] Installing nftables..."
        apt update -y
        apt install -y nftables
    fi
}

init_files() {
    touch "$TCP_FILE" "$UDP_FILE"

    if [ ! -s "$TCP_FILE" ]; then
        cat > "$TCP_FILE" <<'EOT'
22
80
443
EOT
    fi
}

backup_conf() {
    if [ -f "$CONF" ]; then
        cp "$CONF" "$BACKUP_DIR/nftables.conf.$(date +%F-%H%M%S)"
    fi
}

normalize_input() {
    echo "$1" \
        | tr '，' ',' \
        | tr ':' '-' \
        | tr '\n' ',' \
        | tr -d '[:space:]' \
        | sed 's/,,*/,/g; s/^,//; s/,$//'
}

is_valid_item() {
    item="$1"

    if echo "$item" | grep -Eq '^[0-9]+$'; then
        [ "$item" -ge 1 ] && [ "$item" -le 65535 ]
        return
    fi

    if echo "$item" | grep -Eq '^[0-9]+-[0-9]+$'; then
        start="${item%-*}"
        end="${item#*-}"

        [ "$start" -ge 1 ] && \
        [ "$start" -le 65535 ] && \
        [ "$end" -ge 1 ] && \
        [ "$end" -le 65535 ] && \
        [ "$start" -le "$end" ]
        return
    fi

    return 1
}

ports_to_csv() {
    file="$1"

    [ -s "$file" ] || {
        echo ""
        return
    }

    raw="$(cat "$file")"
    norm="$(normalize_input "$raw")"

    [ -n "$norm" ] || {
        echo ""
        return
    }

    result=""

    OLDIFS="$IFS"
    IFS=','
    for item in $norm; do
        IFS="$OLDIFS"

        [ -n "$item" ] || continue

        if is_valid_item "$item"; then
            case ",$result," in
                *,"$item",*) ;;
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

write_csv_to_file() {
    file="$1"
    csv="$2"

    : > "$file"

    csv="$(normalize_input "$csv")"

    [ -n "$csv" ] || return

    OLDIFS="$IFS"
    IFS=','
    for item in $csv; do
        IFS="$OLDIFS"

        [ -n "$item" ] || continue

        if is_valid_item "$item"; then
            echo "$item" >> "$file"
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi

        IFS=','
    done
    IFS="$OLDIFS"
}

build_ruleset_tmp() {
    tmp="$1"

    tcp_ports="$(ports_to_csv "$TCP_FILE")"
    udp_ports="$(ports_to_csv "$UDP_FILE")"

    cat > "$tmp" <<EOF2
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

EOF2

    if [ -n "$tcp_ports" ]; then
        echo "        tcp dport {$tcp_ports} accept" >> "$tmp"
    fi

    if [ -n "$udp_ports" ]; then
        echo "        udp dport {$udp_ports} accept" >> "$tmp"
    fi

    cat >> "$tmp" <<'EOF2'

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        ct state new log prefix "nft-new: " level info

        counter drop
    }

    chain forward {
        type filter hook forward priority 0;
        accept
    }

    chain output {
        type filter hook output priority 0;
        accept
    }
}
EOF2
}

apply_changes() {
    tmp="$(mktemp)"

    build_ruleset_tmp "$tmp"

    echo "[+] Checking nftables config..."
    if nft -c -f "$tmp"; then
        backup_conf
        cp "$tmp" "$CONF"
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl restart nftables
        rm -f "$tmp"

        echo "[OK] nftables applied safely"
        echo ""
        nft list ruleset
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
    ports_to_csv "$TCP_FILE"
    echo ""

    echo "=== UDP saved list ==="
    cat "$UDP_FILE" 2>/dev/null || true
    echo ""

    echo "=== UDP effective nft format ==="
    ports_to_csv "$UDP_FILE"
    echo ""

    echo "=== Current active nft dport rules ==="
    nft list ruleset 2>/dev/null | grep -E 'dport' || echo "No active dport rules found"
}

add_ports() {
    read -p "tcp or udp? (t/u): " proto

    case "$proto" in
        t|T) file="$TCP_FILE" ;;
        u|U) file="$UDP_FILE" ;;
        *) echo "[ERROR] invalid protocol"; return ;;
    esac

    echo "Examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -p "port(s): " input

    input="$(normalize_input "$input")"

    if [ -z "$input" ]; then
        echo "[ERROR] empty input"
        return
    fi

    current="$(ports_to_csv "$file")"

    if [ -n "$current" ]; then
        merged="$current,$input"
    else
        merged="$input"
    fi

    normalized="$(ports_to_csv <(echo "$merged") 2>/dev/null || true)"

    if [ -z "$normalized" ]; then
        echo "[ERROR] no valid ports found"
        return
    fi

    write_csv_to_file "$file" "$normalized"

    echo "[OK] saved ports:"
    cat "$file"

    read -p "Apply now? (y/n): " yn
    case "$yn" in
        y|Y) apply_changes ;;
        *) echo "[INFO] saved but not applied yet" ;;
    esac
}

remove_ports() {
    read -p "tcp or udp? (t/u): " proto

    case "$proto" in
        t|T) file="$TCP_FILE" ;;
        u|U) file="$UDP_FILE" ;;
        *) echo "[ERROR] invalid protocol"; return ;;
    esac

    echo "Examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -p "port(s) to remove: " input

    remove_csv="$(normalize_input "$input")"
    current_csv="$(ports_to_csv "$file")"

    if [ -z "$current_csv" ]; then
        echo "[INFO] no saved ports"
        return
    fi

    if [ -z "$remove_csv" ]; then
        echo "[ERROR] empty remove list"
        return
    fi

    if [ "$file" = "$TCP_FILE" ] && echo "$remove_csv" | grep -Eq '(^|,)22(,|$)'; then
        echo "[WARN] You are removing TCP 22."
        echo "[WARN] Make sure another SSH port is already open and tested."
        read -p "Type YES to continue: " confirm
        [ "$confirm" = "YES" ] || {
            echo "[INFO] cancelled"
            return
        }
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

    write_csv_to_file "$file" "$new_csv"

    echo "[OK] new saved ports:"
    cat "$file" 2>/dev/null || true

    read -p "Apply now? (y/n): " yn
    case "$yn" in
        y|Y) apply_changes ;;
        *) echo "[INFO] saved but not applied yet" ;;
    esac
}

reset_saved_ports() {
    echo "[WARN] This resets saved port lists to default:"
    echo "TCP: 22,80,443"
    echo "UDP: empty"
    read -p "Type YES to reset: " confirm

    [ "$confirm" = "YES" ] || {
        echo "[INFO] cancelled"
        return
    }

    cat > "$TCP_FILE" <<'EOT'
22
80
443
EOT

    : > "$UDP_FILE"

    echo "[OK] saved port lists reset"
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL FINAL ====="
        echo "1) Show ports"
        echo "2) Add port(s)"
        echo "3) Remove port(s)"
        echo "4) Apply changes"
        echo "5) Show nft ruleset"
        echo "6) Reset saved port lists"
        echo "7) Exit"
        echo "=============================="
        read -p "Select: " c

        case "$c" in
            1) show_ports ;;
            2) add_ports ;;
            3) remove_ports ;;
            4) apply_changes ;;
            5) nft list ruleset ;;
            6) reset_saved_ports ;;
            7) exit 0 ;;
            *) echo "invalid" ;;
        esac
    done
}

ensure_nft
init_files
menu
EOF

chmod +x /root/nft_firewall_manager.sh




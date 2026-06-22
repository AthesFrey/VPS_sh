#!/usr/bin/env bash

set -e

CONF="/etc/nftables.conf"
BACKUP_DIR="/etc/nftables.backup"

mkdir -p "$BACKUP_DIR"

# =========================
# DEFAULT PROTECTION PORTS
# =========================
DEFAULT_TCP_PORTS=(22 80 443)

# =========================
# TOOLS
# =========================
ensure_nft() {
    command -v nft >/dev/null 2>&1 || {
        apt update -y
        apt install -y nftables
    }
}

backup() {
    cp "$CONF" "$BACKUP_DIR/nftables.conf.$(date +%F-%H%M%S)" 2>/dev/null || true
}

get_ports() {
    TYPE="$1"
    FILE="/etc/nft_ports_${TYPE}.list"

    # ensure file exists
    touch "$FILE"

    # read + clean
    PORTS=$(cat "$FILE" | grep -E '^[0-9]+$' | sort -n | uniq)

    echo "$PORTS"
}

build_rules() {
    TCP=$(get_ports tcp)
    UDP=$(get_ports udp)

    # merge defaults into TCP
    TCP_ALL=$(printf "%s\n" "${DEFAULT_TCP_PORTS[@]}" "$TCP" | grep -E '^[0-9]+$' | sort -n | uniq | paste -sd "," -)

    UDP_ALL=$(echo "$UDP" | tr '\n' ',' | sed 's/,$//')

    cat > "$CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # TCP ports (always safe, never empty)
        tcp dport {${TCP_ALL}} accept

EOF

    # only add UDP if not empty
    if [ -n "$UDP_ALL" ]; then
        echo "        udp dport {${UDP_ALL}} accept" >> "$CONF"
    fi

    cat >> "$CONF" <<EOF

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        ct state new log prefix "nft-new: " level info

        counter drop
    }

    chain forward {
        type filter hook forward priority 0;
        counter drop
    }

    chain output {
        type filter hook output priority 0;
        accept
    }
}
EOF
}

validate() {
    nft -c -f "$CONF"
}

apply() {
    backup
    build_rules

    if validate; then
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl restart nftables
        echo "[OK] nftables applied safely"
    else
        echo "[ERROR] invalid config, rollback"
        latest=$(ls -t $BACKUP_DIR/*.conf* 2>/dev/null | head -1)
        [ -n "$latest" ] && cp "$latest" "$CONF"
        systemctl restart nftables || true
        exit 1
    fi
}

show_ports() {
    echo "=== TCP ==="
    cat /etc/nft_ports_tcp.list 2>/dev/null || true
    echo "=== UDP ==="
    cat /etc/nft_ports_udp.list 2>/dev/null || true
}

add_port() {
    read -p "tcp or udp? (t/u): " proto
    read -p "port: " port

    FILE="/etc/nft_ports_${proto}cp.list"
    if [ "$proto" = "t" ]; then
        FILE="/etc/nft_ports_tcp.list"
    else
        FILE="/etc/nft_ports_udp.list"
    fi

    echo "$port" >> "$FILE"
    sort -n "$FILE" | uniq > tmp && mv tmp "$FILE"

    echo "[OK] added $port"
}

remove_port() {
    read -p "tcp or udp? (t/u): " proto
    read -p "port: " port

    FILE="/etc/nft_ports_tcp.list"
    [ "$proto" = "u" ] && FILE="/etc/nft_ports_udp.list"

    grep -v "^$port$" "$FILE" > tmp && mv tmp "$FILE"
    echo "[OK] removed $port"
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL v2 ====="
        echo "1) Show ports"
        echo "2) Add port"
        echo "3) Remove port"
        echo "4) Apply changes"
        echo "5) Exit"
        echo "==========================="
        read -p "Select: " c

        case $c in
            1) show_ports ;;
            2) add_port ;;
            3) remove_port ;;
            4) apply ;;
            5) exit 0 ;;
            *) echo "invalid" ;;
        esac
    done
}

# =========================
# INIT
# =========================
ensure_nft

touch /etc/nft_ports_tcp.list
touch /etc/nft_ports_udp.list

# ensure defaults exist
for p in 22 80 443; do
    grep -qx "$p" /etc/nft_ports_tcp.list || echo "$p" >> /etc/nft_ports_tcp.list
done

apply
menu

#!/usr/bin/env bash

set -e

CONF="/etc/nftables.conf"

DEFAULT_PORTS_TCP=(22 80 443)

ensure_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "[+] Installing nftables..."
        apt update -y
        apt install -y nftables
    fi
}

backup_conf() {
    if [ -f "$CONF" ]; then
        cp "$CONF" "$CONF.bak.$(date +%F-%H%M%S)"
    fi
}

build_ruleset() {
    TCP_PORTS=$(get_ports tcp)
    UDP_PORTS=$(get_ports udp)

    cat > "$CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        tcp dport {${TCP_PORTS}} accept
        udp dport {${UDP_PORTS}} accept

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

get_ports() {
    TYPE="$1"
    FILE="/etc/nft_ports_$TYPE.list"

    if [ ! -f "$FILE" ]; then
        if [ "$TYPE" = "tcp" ]; then
            echo "${DEFAULT_PORTS_TCP[*]}" | tr ' ' ','
        else
            echo ""
        fi
        return
    fi

    paste -sd "," "$FILE"
}

save_ports() {
    TYPE="$1"
    FILE="/etc/nft_ports_$TYPE.list"
    shift
    echo "$@" | tr ' ' '\n' | sort -n | uniq > "$FILE"
}

show_ports() {
    echo "=== TCP Ports ==="
    cat /etc/nft_ports_tcp.list 2>/dev/null || echo "22 80 443 (default)"
    echo "=== UDP Ports ==="
    cat /etc/nft_ports_udp.list 2>/dev/null || echo "none"
}

add_port() {
    read -p "TCP or UDP? (t/u): " proto
    read -p "Port number: " port

    if [[ "$proto" == "t" ]]; then
        FILE="/etc/nft_ports_tcp.list"
    else
        FILE="/etc/nft_ports_udp.list"
    fi

    touch "$FILE"
    echo "$port" >> "$FILE"
    sort -n "$FILE" | uniq > "$FILE"

    echo "[+] Added $port to $proto"
}

remove_port() {
    read -p "TCP or UDP? (t/u): " proto
    read -p "Port number to remove: " port

    if [[ "$proto" == "t" ]]; then
        FILE="/etc/nft_ports_tcp.list"
    else
        FILE="/etc/nft_ports_udp.list"
    fi

    if [ -f "$FILE" ]; then
        grep -v "^$port$" "$FILE" > tmp && mv tmp "$FILE"
        echo "[+] Removed $port"
    else
        echo "No such list"
    fi
}

apply() {
    build_ruleset
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables

    echo "[+] nftables applied"
    nft list ruleset
}

menu() {
    while true; do
        echo ""
        echo "=============================="
        echo " NFT FIREWALL MANAGER"
        echo "=============================="
        echo "1) Show ports"
        echo "2) Add port"
        echo "3) Remove port"
        echo "4) Apply & restart nftables"
        echo "5) Exit"
        echo "=============================="
        read -p "Select: " opt

        case $opt in
            1) show_ports ;;
            2) add_port ;;
            3) remove_port ;;
            4) apply ;;
            5) exit 0 ;;
            *) echo "Invalid" ;;
        esac
    done
}

# ======================
# INIT
# ======================
ensure_nft
backup_conf

# init default ports if not exist
if [ ! -f /etc/nft_ports_tcp.list ]; then
    echo "22 80 443" | tr ' ' '\n' > /etc/nft_ports_tcp.list
fi

if [ ! -f /etc/nft_ports_udp.list ]; then
    touch /etc/nft_ports_udp.list
fi

# first run auto apply
build_ruleset
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

menu


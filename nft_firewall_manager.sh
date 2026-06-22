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

backup_conf() {
    if [ -f "$CONF" ]; then
        cp "$CONF" "$BACKUP_DIR/nftables.conf.$(date +%F-%H%M%S)"
    fi
}

init_port_files() {
    touch "$TCP_FILE" "$UDP_FILE"

    if [ ! -s "$TCP_FILE" ]; then
        cat > "$TCP_FILE" <<EOF
22
80
443
EOF
    fi
}

normalize_ports() {
    # Input can be:
    # 3556
    # 3666-3669
    # 3556,3666-3669,15000-18369
    #
    # Output:
    # 3556,3666-3669,15000-18369

    tr '\n' ',' \
    | tr -d '[:space:]' \
    | sed 's/，/,/g' \
    | sed 's/--*/-/g' \
    | sed 's/,,*/,/g' \
    | sed 's/^,//;s/,$//' \
    | awk -F',' '
        function valid_port(p) {
            return (p ~ /^[0-9]+$/ && p >= 1 && p <= 65535)
        }

        function valid_range(r, a) {
            split(r, a, "-")
            return (
                a[1] ~ /^[0-9]+$/ &&
                a[2] ~ /^[0-9]+$/ &&
                a[1] >= 1 && a[1] <= 65535 &&
                a[2] >= 1 && a[2] <= 65535 &&
                a[1] <= a[2]
            )
        }

        {
            for (i=1; i<=NF; i++) {
                item=$i

                if (item == "") {
                    continue
                }

                if (item ~ /^[0-9]+$/ && valid_port(item)) {
                    seen[item]=1
                } else if (item ~ /^[0-9]+-[0-9]+$/ && valid_range(item)) {
                    seen[item]=1
                } else {
                    bad[item]=1
                }
            }
        }

        END {
            first=1
            for (x in seen) {
                if (!first) {
                    printf ","
                }
                printf "%s", x
                first=0
            }

            if (length(bad) > 0) {
                printf "\n" > "/dev/stderr"
                for (b in bad) {
                    printf "[WARN] ignored invalid port item: %s\n", b > "/dev/stderr"
                }
            }
        }
    '
}

get_ports_csv() {
    local file="$1"

    if [ ! -s "$file" ]; then
        echo ""
        return
    fi

    normalize_ports < "$file"
}

write_ports_file() {
    local file="$1"
    local input="$2"

    echo "$input" \
    | tr ',' '\n' \
    | tr -d '[:space:]' \
    | sed '/^$/d' \
    > "$file"
}

build_ruleset_to_tmp() {
    local tmp="$1"
    local tcp_ports
    local udp_ports

    tcp_ports="$(get_ports_csv "$TCP_FILE")"
    udp_ports="$(get_ports_csv "$UDP_FILE")"

    cat > "$tmp" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    chain input {
        type filter hook input priority 0;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

EOF

    if [ -n "$tcp_ports" ]; then
        echo "        tcp dport {$tcp_ports} accept" >> "$tmp"
    fi

    if [ -n "$udp_ports" ]; then
        echo "        udp dport {$udp_ports} accept" >> "$tmp"
    fi

    cat >> "$tmp" <<EOF

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
EOF
}

apply_changes() {
    local tmp
    tmp="$(mktemp)"

    build_ruleset_to_tmp "$tmp"

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
    echo "=== TCP raw list ==="
    cat "$TCP_FILE" 2>/dev/null || true
    echo ""
    echo "=== TCP effective nft format ==="
    get_ports_csv "$TCP_FILE"
    echo ""

    echo "=== UDP raw list ==="
    cat "$UDP_FILE" 2>/dev/null || true
    echo ""
    echo "=== UDP effective nft format ==="
    get_ports_csv "$UDP_FILE"
    echo ""
}

add_port() {
    local proto file input current merged normalized

    read -p "tcp or udp? (t/u): " proto
    case "$proto" in
        t|T) file="$TCP_FILE" ;;
        u|U) file="$UDP_FILE" ;;
        *) echo "[ERROR] invalid protocol"; return ;;
    esac

    echo "Input examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -p "port(s): " input

    normalized="$(echo "$input" | normalize_ports)"
    if [ -z "$normalized" ]; then
        echo "[ERROR] no valid port found"
        return
    fi

    current="$(get_ports_csv "$file")"

    if [ -n "$current" ]; then
        merged="$current,$normalized"
    else
        merged="$normalized"
    fi

    normalized="$(echo "$merged" | normalize_ports)"
    write_ports_file "$file" "$normalized"

    echo "[OK] added: $normalized"

    read -p "Apply now? (y/n): " yn
    case "$yn" in
        y|Y) apply_changes ;;
        *) echo "[INFO] changes saved, not applied yet" ;;
    esac
}

remove_port() {
    local proto file input remove_csv current new_csv

    read -p "tcp or udp? (t/u): " proto
    case "$proto" in
        t|T) file="$TCP_FILE" ;;
        u|U) file="$UDP_FILE" ;;
        *) echo "[ERROR] invalid protocol"; return ;;
    esac

    echo "Remove examples:"
    echo "  3556"
    echo "  3666-3669"
    echo "  3556,3666-3669,15000-18369"
    read -p "port(s) to remove: " input

    remove_csv="$(echo "$input" | normalize_ports)"
    current="$(get_ports_csv "$file")"

    if [ -z "$current" ]; then
        echo "[INFO] no ports exist"
        return
    fi

    new_csv="$(awk -v cur="$current" -v rem="$remove_csv" '
        BEGIN {
            split(rem, r, ",")
            for (i in r) remove[r[i]]=1

            split(cur, c, ",")
            first=1
            for (i in c) {
                if (!(c[i] in remove)) {
                    if (!first) printf ","
                    printf "%s", c[i]
                    first=0
                }
            }
        }
    ')"

    if [ "$input" = "22" ] || echo "$remove_csv" | grep -Eq '(^|,)22(,|$)'; then
        echo "[WARN] You are removing TCP 22. Make sure another SSH port is already open and tested."
        read -p "Really continue? Type YES: " confirm
        [ "$confirm" = "YES" ] || {
            echo "[INFO] cancelled"
            return
        }
    fi

    write_ports_file "$file" "$new_csv"

    echo "[OK] removed. New list: $new_csv"

    read -p "Apply now? (y/n): " yn
    case "$yn" in
        y|Y) apply_changes ;;
        *) echo "[INFO] changes saved, not applied yet" ;;
    esac
}

menu() {
    while true; do
        echo ""
        echo "===== NFT FIREWALL v3 ====="
        echo "1) Show ports"
        echo "2) Add port(s)"
        echo "3) Remove port(s)"
        echo "4) Apply changes"
        echo "5) Show nft ruleset"
        echo "6) Exit"
        echo "==========================="
        read -p "Select: " c

        case "$c" in
            1) show_ports ;;
            2) add_port ;;
            3) remove_port ;;
            4) apply_changes ;;
            5) nft list ruleset ;;
            6) exit 0 ;;
            *) echo "invalid" ;;
        esac
    done
}



ensure_nft
init_port_files
menu

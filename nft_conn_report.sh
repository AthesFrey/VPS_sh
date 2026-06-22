#!/usr/bin/env bash

set -e

export TZ=Asia/Tokyo

LOG_PREFIX="${LOG_PREFIX:-nft-new:}"
TOP_N="${TOP_N:-10}"
PORT_LIMIT="${PORT_LIMIT:-0}"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

line() {
    echo "============================================================"
}

pause() {
    echo ""
    read -r -p "Press Enter to continue..."
}

usage() {
    cat <<'EOF_USAGE'
Usage:
  bash /root/nft_conn_report_top10.sh daily
  bash /root/nft_conn_report_top10.sh weekly
  bash /root/nft_conn_report_top10.sh custom
  bash /root/nft_conn_report_top10.sh status

Optional environment variables:
  LOG_PREFIX='nft-new:' bash /root/nft_conn_report_top10.sh daily
  TOP_N=20 bash /root/nft_conn_report_top10.sh daily
  PORT_LIMIT=20 bash /root/nft_conn_report_top10.sh daily

Defaults:
  TOP_N=10
  PORT_LIMIT=0    Show all ports under each top IP. Set to 20/50 if output is too long.
  Time zone: Asia/Tokyo / JST

Traffic note:
  Traffic is calculated from packet length fields in the nft/kernel log, for example LEN=60.
  If your log rule only records ct state new packets, this is logged packet bytes, not full
  connection traffic. For exact per-flow traffic, use nftables counters or conntrack accounting.
EOF_USAGE
}

need_tools_check() {
    if ! has_cmd journalctl; then
        echo "[ERROR] journalctl not found"
        exit 1
    fi

    if ! has_cmd date; then
        echo "[ERROR] date not found"
        exit 1
    fi
}

get_journal_logs() {
    start="$1"
    end="$2"

    journalctl -k -o short-iso --since "$start" --until "$end" --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" || true
}

extract_logs_csv() {
    awk '
    function clean(v) {
        gsub(/[,;]/, "", v)
        return v
    }

    {
        ts=$1
        src=""
        dpt=""
        proto=""
        pkt_len=""

        for (i=1; i<=NF; i++) {
            if ($i ~ /^SRC=/) {
                split($i,a,"=")
                src=clean(a[2])
            }

            if ($i ~ /^DPT=/) {
                split($i,b,"=")
                dpt=clean(b[2])
            }

            if ($i ~ /^PROTO=/) {
                split($i,c,"=")
                proto=tolower(clean(c[2]))
            }

            if ($i ~ /^[Ll][Ee][Nn]=/) {
                split($i,d,"=")
                pkt_len=clean(d[2])
                if (pkt_len !~ /^[0-9]+$/) {
                    pkt_len=""
                }
            }
        }

        if (src != "" && dpt != "") {
            if (proto == "") {
                proto="unknown"
            }

            print ts "," proto "," src "," dpt "," pkt_len
        }
    }
    '
}

human_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KiB MiB GiB TiB PiB", u, " ")
        i=1
        while (b >= 1024 && i < 6) {
            b = b / 1024
            i++
        }
        if (i == 1) {
            printf "%.0f %s", b, u[i]
        } else {
            printf "%.2f %s", b, u[i]
        }
    }'
}

emit_port_rows() {
    csv_file="$1"
    ip="$2"
    len_seen="$3"

    if [ "$len_seen" -eq 1 ]; then
        awk -F',' -v ip="$ip" '
        NF>=5 && $3==ip {
            key=$2"/"$4
            count[key]++
            if ($5 ~ /^[0-9]+$/) {
                bytes[key]+=$5
            }
        }
        END {
            for (k in count) {
                print count[k], bytes[k]+0, k
            }
        }' "$csv_file" \
            | sort -k1,1nr -k2,2nr \
            | awk -v limit="$PORT_LIMIT" '
            function human(b,    i,u) {
                split("B KiB MiB GiB TiB PiB", u, " ")
                i=1
                while (b >= 1024 && i < 6) {
                    b = b / 1024
                    i++
                }
                if (i == 1) return sprintf("%.0f %s", b, u[i])
                return sprintf("%.2f %s", b, u[i])
            }
            BEGIN {
                printf "  %-8s %-14s %s\n", "HITS", "TRAFFIC", "PROTO/PORT"
            }
            limit == 0 || NR <= limit {
                printf "  %-8s %-14s %s\n", $1, human($2), $3
            }'
    else
        awk -F',' -v ip="$ip" '
        NF>=4 && $3==ip {
            key=$2"/"$4
            count[key]++
        }
        END {
            for (k in count) {
                print count[k], k
            }
        }' "$csv_file" \
            | sort -k1,1nr \
            | awk -v limit="$PORT_LIMIT" '
            BEGIN {
                printf "  %-8s %s\n", "HITS", "PROTO/PORT"
            }
            limit == 0 || NR <= limit {
                printf "  %-8s %s\n", $1, $2
            }'
    fi
}

report_top_ip_details() {
    csv_file="$1"
    start="$2"
    end="$3"

    len_seen="$(awk -F',' 'NF>=5 && $5 ~ /^[0-9]+$/ {seen=1} END {print seen+0}' "$csv_file")"

    line
    echo "TOP ${TOP_N} IP DETAILS: PORTS + ACTIVE TIME RANGE JST"
    line
    echo "Range     : $start -> $end"
    echo "Log prefix: $LOG_PREFIX"

    if [ "$len_seen" -eq 1 ]; then
        total_bytes="$(awk -F',' 'NF>=5 && $5 ~ /^[0-9]+$/ {sum+=$5} END {print sum+0}' "$csv_file")"
        echo "Traffic   : logged packet length total = $(human_bytes "$total_bytes") ($total_bytes bytes)"
    else
        echo "Traffic   : unknown, no LEN= field found in matched logs"
    fi

    top_ips="$(awk -F',' 'NF>=4 {count[$3]++} END {for (ip in count) print count[ip], ip}' "$csv_file" \
        | sort -k1,1nr \
        | head -n "$TOP_N" \
        | awk '{print $2}')"

    if [ -z "$top_ips" ]; then
        echo "No data"
        return
    fi

    for ip in $top_ips; do
        hits="$(awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {c++} END {print c+0}' "$csv_file")"
        first_seen="$(awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' "$csv_file" | sort | head -n 1)"
        last_seen="$(awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' "$csv_file" | sort | tail -n 1)"

        echo ""
        echo "IP: $ip"
        echo "Hits: $hits"

        if [ "$len_seen" -eq 1 ]; then
            ip_bytes="$(awk -F',' -v ip="$ip" 'NF>=5 && $3==ip && $5 ~ /^[0-9]+$/ {sum+=$5} END {print sum+0}' "$csv_file")"
            echo "Logged traffic: $(human_bytes "$ip_bytes") ($ip_bytes bytes)"
        else
            echo "Logged traffic: unknown"
        fi

        echo "First seen: $first_seen JST"
        echo "Last seen : $last_seen JST"
        echo "Ports:"

        emit_port_rows "$csv_file" "$ip" "$len_seen"
    done
}

run_report() {
    title="$1"
    start="$2"
    end="$3"

    clear || true

    tmp_raw="$(mktemp)"
    tmp_csv="$(mktemp)"
    trap 'rm -f "$tmp_raw" "$tmp_csv"' EXIT

    get_journal_logs "$start" "$end" > "$tmp_raw"
    extract_logs_csv < "$tmp_raw" > "$tmp_csv"

    if [ ! -s "$tmp_csv" ]; then
        line
        echo "NO CONNECTION LOGS FOUND"
        line
        echo "Report     : $title"
        echo "Range      : $start -> $end"
        echo "Log prefix : $LOG_PREFIX"
        echo ""
        echo "Try:"
        echo "  journalctl -k --no-pager | grep 'nft-new:' | tail"
        echo "  nft list ruleset | grep log"
        return
    fi

    report_top_ip_details "$tmp_csv" "$start" "$end"
}

daily_report() {
    start="$(date '+%Y-%m-%d 00:00:00')"
    end="$(date '+%Y-%m-%d 23:59:59')"
    run_report "DAILY NFT CONNECTION REPORT" "$start" "$end"
}

weekly_report() {
    start="$(date -d '6 days ago' '+%Y-%m-%d 00:00:00')"
    end="$(date '+%Y-%m-%d 23:59:59')"
    run_report "WEEKLY NFT CONNECTION REPORT" "$start" "$end"
}

custom_report() {
    echo "Input start date, example: 2026-06-22"
    read -r -p "Start date: " s

    echo "Input end date, example: 2026-06-22"
    read -r -p "End date: " e

    if ! date -d "$s" >/dev/null 2>&1 || ! date -d "$e" >/dev/null 2>&1; then
        echo "[ERROR] invalid date"
        return
    fi

    start="$s 00:00:00"
    end="$e 23:59:59"
    run_report "CUSTOM NFT CONNECTION REPORT" "$start" "$end"
}

check_status() {
    line
    echo "STATUS CHECK"
    line

    echo ""
    echo "[nftables service]"
    systemctl is-active nftables 2>/dev/null || true

    echo ""
    echo "[nft log rule]"
    nft list ruleset 2>/dev/null | grep -E 'log prefix|dport' || true

    echo ""
    echo "[recent logs]"
    journalctl -k --no-pager 2>/dev/null | grep -F "$LOG_PREFIX" | tail -n 10 || true
}

menu() {
    while true; do
        echo ""
        echo "===== NFT CONNECTION REPORT TOP10 ====="
        echo "1) Daily report"
        echo "2) Weekly report"
        echo "3) Custom date range"
        echo "4) Status check"
        echo "5) Help"
        echo "6) Exit"
        echo "======================================="
        read -r -p "Select: " c

        case "$c" in
            1)
                daily_report
                pause
                ;;
            2)
                weekly_report
                pause
                ;;
            3)
                custom_report
                pause
                ;;
            4)
                check_status
                pause
                ;;
            5)
                usage
                pause
                ;;
            6)
                exit 0
                ;;
            *)
                echo "invalid"
                ;;
        esac
    done
}

need_tools_check

case "${1:-}" in
    daily)
        daily_report
        ;;
    weekly)
        weekly_report
        ;;
    custom)
        custom_report
        ;;
    status)
        check_status
        ;;
    help|-h|--help)
        usage
        ;;
    "")
        menu
        ;;
    *)
        usage
        exit 1
        ;;
esac

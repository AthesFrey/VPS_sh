#!/usr/bin/env bash

set -e

export TZ=Asia/Tokyo

LOG_PREFIX="${LOG_PREFIX:-nft-new:}"
LIMIT="${LIMIT:-20}"
TOP_N="${TOP_N:-5}"
VNSTAT_IFACE="${VNSTAT_IFACE:-}"

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
    cat <<'EOF'
Usage:
  bash /root/nft_conn_report.sh

Optional environment variables:
  LIMIT=50 bash /root/nft_conn_report.sh
  TOP_N=10 bash /root/nft_conn_report.sh
  VNSTAT_IFACE=eth0 bash /root/nft_conn_report.sh

Modes:
  Daily report
  Weekly report
  Custom date range

Time zone:
  Asia/Tokyo / JST
EOF
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

vnstat_cmd_base() {
    if ! has_cmd vnstat; then
        return 1
    fi

    if [ -n "$VNSTAT_IFACE" ]; then
        printf "vnstat -i %s" "$VNSTAT_IFACE"
    else
        printf "vnstat"
    fi
}

get_journal_logs() {
    start="$1"
    end="$2"

    journalctl -k --since "$start" --until "$end" --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" || true
}

extract_logs_csv() {
    awk '
    function clean(v) {
        gsub(/[,;]/, "", v)
        return v
    }

    {
        src=""
        dpt=""
        proto=""
        ts=$1" "$2" "$3

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
        }

        if (src != "" && dpt != "") {
            if (proto == "") {
                proto="unknown"
            }

            print ts "," proto "," src "," dpt
        }
    }
    '
}

report_summary() {
    logs="$1"

    total="$(printf "%s\n" "$logs" | sed '/^$/d' | wc -l | tr -d ' ')"
    unique_ips="$(printf "%s\n" "$logs" | awk -F',' 'NF>=4 {print $3}' | sort -u | wc -l | tr -d ' ')"
    unique_ports="$(printf "%s\n" "$logs" | awk -F',' 'NF>=4 {print $4}' | sort -u | wc -l | tr -d ' ')"

    line
    echo "SUMMARY"
    line
    echo "Total new connections : $total"
    echo "Unique source IPs     : $unique_ips"
    echo "Unique destination ports: $unique_ports"
}

report_top_ips() {
    logs="$1"

    line
    echo "TOP ${TOP_N} SOURCE IPs"
    line

    printf "%s\n" "$logs" \
        | awk -F',' 'NF>=4 {count[$3]++} END {for (ip in count) print count[ip], ip}' \
        | sort -nr \
        | head -n "$TOP_N" \
        | awk '{printf "%-8s %s\n", $1, $2}'
}

report_top_ip_ports() {
    logs="$1"

    line
    echo "TOP ${LIMIT} SOURCE IP + DEST PORT"
    line

    printf "%s\n" "$logs" \
        | awk -F',' 'NF>=4 {
            key=$3","$2","$4
            count[key]++
        }
        END {
            for (k in count) {
                split(k,a,",")
                print count[k], a[1], a[2], a[3]
            }
        }' \
        | sort -nr \
        | head -n "$LIMIT" \
        | awk 'BEGIN {
            printf "%-8s %-40s %-8s %-8s\n", "HITS", "SRC_IP", "PROTO", "DPT"
        }
        {
            printf "%-8s %-40s %-8s %-8s\n", $1, $2, $3, $4
        }'
}

report_ports() {
    logs="$1"

    line
    echo "TOP DESTINATION PORTS"
    line

    printf "%s\n" "$logs" \
        | awk -F',' 'NF>=4 {
            key=$2","$4
            count[key]++
        }
        END {
            for (k in count) {
                split(k,a,",")
                print count[k], a[1], a[2]
            }
        }' \
        | sort -nr \
        | head -n "$LIMIT" \
        | awk 'BEGIN {
            printf "%-8s %-8s %-8s\n", "HITS", "PROTO", "DPT"
        }
        {
            printf "%-8s %-8s %-8s\n", $1, $2, $3
        }'
}

report_time_buckets() {
    logs="$1"

    line
    echo "CONNECTIONS BY HOUR JST"
    line

    printf "%s\n" "$logs" \
        | awk -F',' 'NF>=4 {
            split($1,t," ")
            hour=t[2]
            sub(/:.*/, "", hour)
            if (hour ~ /^[0-9][0-9]$/) {
                count[hour]++
            }
        }
        END {
            for (h=0; h<24; h++) {
                hh=sprintf("%02d", h)
                printf "%s:00-%s:59 %d\n", hh, hh, count[hh]+0
            }
        }'
}

report_top5_detail() {
    logs="$1"

    line
    echo "TOP ${TOP_N} IP DETAILS: PORTS + ACTIVE TIME RANGE JST"
    line

    top_ips="$(printf "%s\n" "$logs" \
        | awk -F',' 'NF>=4 {count[$3]++} END {for (ip in count) print count[ip], ip}' \
        | sort -nr \
        | head -n "$TOP_N" \
        | awk '{print $2}')"

    if [ -z "$top_ips" ]; then
        echo "No data"
        return
    fi

    for ip in $top_ips; do
        hits="$(printf "%s\n" "$logs" | awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {c++} END {print c+0}')"

        first_seen="$(printf "%s\n" "$logs" | awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' | sort | head -n 1)"
        last_seen="$(printf "%s\n" "$logs" | awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' | sort | tail -n 1)"

        echo ""
        echo "IP: $ip"
        echo "Hits: $hits"
        echo "First seen: $first_seen JST"
        echo "Last seen : $last_seen JST"
        echo "Ports:"

        printf "%s\n" "$logs" \
            | awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {
                key=$2"/"$4
                count[key]++
            }
            END {
                for (k in count) print count[k], k
            }' \
            | sort -nr \
            | head -n "$LIMIT" \
            | awk '{printf "  %-8s %s\n", $1, $2}'
    done
}

vnstat_report_daily() {
    line
    echo "VNSTAT DAILY TRAFFIC"
    line

    if ! has_cmd vnstat; then
        echo "vnstat not installed"
        return
    fi

    if [ -n "$VNSTAT_IFACE" ]; then
        vnstat -i "$VNSTAT_IFACE" -d
    else
        vnstat -d
    fi
}

vnstat_report_weekly() {
    line
    echo "VNSTAT WEEKLY TRAFFIC"
    line

    if ! has_cmd vnstat; then
        echo "vnstat not installed"
        return
    fi

    if [ -n "$VNSTAT_IFACE" ]; then
        vnstat -i "$VNSTAT_IFACE" -w
    else
        vnstat -w
    fi
}

run_report() {
    title="$1"
    start="$2"
    end="$3"
    vn_mode="$4"

    clear || true

    line
    echo "$title"
    line
    echo "Time zone : Asia/Tokyo / JST"
    echo "Range     : $start -> $end"
    echo "Log prefix: $LOG_PREFIX"
    echo "Top N     : $TOP_N"
    echo "Limit     : $LIMIT"

    raw_logs="$(get_journal_logs "$start" "$end")"
    logs="$(printf "%s\n" "$raw_logs" | extract_logs_csv)"

    if [ -z "$logs" ]; then
        line
        echo "NO CONNECTION LOGS FOUND"
        line
        echo "Possible reasons:"
        echo "1. nftables logging rule has not generated logs yet"
        echo "2. Log prefix is different"
        echo "3. journal logs were rotated or unavailable"
        echo ""
        echo "Try:"
        echo "  journalctl -k --no-pager | grep 'nft-new:' | tail"
        echo "  nft list ruleset | grep log"
        echo ""
        case "$vn_mode" in
            daily) vnstat_report_daily ;;
            weekly) vnstat_report_weekly ;;
        esac
        return
    fi

    report_summary "$logs"
    report_top_ips "$logs"
    report_top_ip_ports "$logs"
    report_ports "$logs"
    report_time_buckets "$logs"
    report_top5_detail "$logs"

    case "$vn_mode" in
        daily)
            vnstat_report_daily
            ;;
        weekly)
            vnstat_report_weekly
            ;;
    esac
}

daily_report() {
    start="$(date '+%Y-%m-%d 00:00:00')"
    end="$(date '+%Y-%m-%d 23:59:59')"

    run_report "DAILY NFT CONNECTION REPORT" "$start" "$end" "daily"
}

weekly_report() {
    start="$(date -d '6 days ago' '+%Y-%m-%d 00:00:00')"
    end="$(date '+%Y-%m-%d 23:59:59')"

    run_report "WEEKLY NFT CONNECTION REPORT" "$start" "$end" "weekly"
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

    run_report "CUSTOM NFT CONNECTION REPORT" "$start" "$end" "daily"
}

raw_logs_tail() {
    line
    echo "RAW NFT LOGS TAIL"
    line

    journalctl -k --no-pager 2>/dev/null | grep -F "$LOG_PREFIX" | tail -n 50 || true
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

    echo ""
    echo "[vnstat]"
    if has_cmd vnstat; then
        if [ -n "$VNSTAT_IFACE" ]; then
            vnstat -i "$VNSTAT_IFACE" --oneline 2>/dev/null || true
        else
            vnstat --oneline 2>/dev/null || true
        fi
    else
        echo "vnstat not installed"
    fi
}

menu() {
    while true; do
        echo ""
        echo "===== NFT CONNECTION REPORT ====="
        echo "1) Daily report"
        echo "2) Weekly report"
        echo "3) Custom date range"
        echo "4) Show recent raw nft logs"
        echo "5) Status check"
        echo "6) Help"
        echo "7) Exit"
        echo "================================="
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
                raw_logs_tail
                pause
                ;;
            5)
                check_status
                pause
                ;;
            6)
                usage
                pause
                ;;
            7)
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
    raw)
        raw_logs_tail
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

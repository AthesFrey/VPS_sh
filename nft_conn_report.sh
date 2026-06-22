#!/usr/bin/env bash

set -e

# Output/report timezone. Default is UTC+8.
# You may set REPORT_TZ=Asia/Singapore if preferred; both are UTC+8.
REPORT_TZ="${REPORT_TZ:-Asia/Shanghai}"
REPORT_TZ_LABEL="${REPORT_TZ_LABEL:-UTC+8}"

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
  bash /root/nft_conn_report_top10_utc8_folded.sh daily
  bash /root/nft_conn_report_top10_utc8_folded.sh weekly
  bash /root/nft_conn_report_top10_utc8_folded.sh custom
  bash /root/nft_conn_report_top10_utc8_folded.sh status

Optional environment variables:
  LOG_PREFIX='nft-new:' bash /root/nft_conn_report_top10_utc8_folded.sh daily
  TOP_N=20 bash /root/nft_conn_report_top10_utc8_folded.sh daily
  PORT_LIMIT=20 bash /root/nft_conn_report_top10_utc8_folded.sh daily
  REPORT_TZ=Asia/Singapore bash /root/nft_conn_report_top10_utc8_folded.sh daily

Defaults:
  TOP_N=10
  PORT_LIMIT=0        Show all repeated ports under each top IP.
                      Ports with HITS=1 are always folded and not listed.
  REPORT_TZ=Asia/Shanghai
  REPORT_TZ_LABEL=UTC+8

Timezone note:
  This script reads journal entries with journalctl -o short-unix, then converts the
  stored epoch timestamp to REPORT_TZ for display. This avoids confusion when the
  server, journal output, or pasted logs were generated under other time zones such
  as Europe/Rome, Asia/Singapore, or Asia/Tokyo.

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

    if ! TZ="$REPORT_TZ" date '+%Y-%m-%d %H:%M:%S %z' >/dev/null 2>&1; then
        echo "[ERROR] invalid REPORT_TZ: $REPORT_TZ"
        exit 1
    fi
}

format_epoch() {
    epoch="$1"
    TZ="$REPORT_TZ" date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z'
}

format_range_time() {
    local_time="$1"
    TZ="$REPORT_TZ" date -d "$local_time" '+%Y-%m-%d %H:%M:%S %z'
}

get_journal_logs() {
    start_local="$1"
    end_local="$2"

    since_arg="$(format_range_time "$start_local")"
    until_arg="$(format_range_time "$end_local")"

    journalctl -k -o short-unix --since "$since_arg" --until "$until_arg" --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" || true
}

extract_logs_csv() {
    awk '
    function clean(v) {
        gsub(/[,;]/, "", v)
        return v
    }

    {
        epoch=$1
        sub(/\..*/, "", epoch)
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

        if (epoch ~ /^[0-9]+$/ && src != "" && dpt != "") {
            if (proto == "") {
                proto="unknown"
            }

            print epoch "," proto "," src "," dpt "," pkt_len
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

    tmp_ports="$(mktemp)"

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
        }' "$csv_file" > "$tmp_ports"

        repeated_total="$(awk '$1 > 1 {c++} END {print c+0}' "$tmp_ports")"
        single_stats="$(awk '$1 == 1 {ports++; hits+=$1; bytes+=$2} END {print ports+0, hits+0, bytes+0}' "$tmp_ports")"
        single_ports="$(printf "%s\n" "$single_stats" | awk '{print $1}')"
        single_hits="$(printf "%s\n" "$single_stats" | awk '{print $2}')"
        single_bytes="$(printf "%s\n" "$single_stats" | awk '{print $3}')"

        echo "Repeated ports with HITS > 1: $repeated_total"

        if [ "$repeated_total" -gt 0 ]; then
            awk '$1 > 1 {print $0}' "$tmp_ports" \
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
                    shown=0
                    printf "  %-8s %-14s %s\n", "HITS", "TRAFFIC", "PROTO/PORT"
                }
                limit == 0 || shown < limit {
                    shown++
                    printf "  %-8s %-14s %s\n", $1, human($2), $3
                }
                END {
                    if (limit > 0 && NR > limit) {
                        printf "  ... %d repeated port rows hidden by PORT_LIMIT\n", NR - limit
                    }
                }'
        fi

        if [ "$single_ports" -gt 0 ]; then
            echo "Single-hit ports folded: $single_ports ports / $single_hits hits, $(human_bytes "$single_bytes") ($single_bytes bytes)"
        else
            echo "Single-hit ports folded: 0 ports / 0 hits, 0 B (0 bytes)"
        fi
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
        }' "$csv_file" > "$tmp_ports"

        repeated_total="$(awk '$1 > 1 {c++} END {print c+0}' "$tmp_ports")"
        single_ports="$(awk '$1 == 1 {c++} END {print c+0}' "$tmp_ports")"
        single_hits="$single_ports"

        echo "Repeated ports with HITS > 1: $repeated_total"

        if [ "$repeated_total" -gt 0 ]; then
            awk '$1 > 1 {print $0}' "$tmp_ports" \
                | sort -k1,1nr \
                | awk -v limit="$PORT_LIMIT" '
                BEGIN {
                    shown=0
                    printf "  %-8s %s\n", "HITS", "PROTO/PORT"
                }
                limit == 0 || shown < limit {
                    shown++
                    printf "  %-8s %s\n", $1, $2
                }
                END {
                    if (limit > 0 && NR > limit) {
                        printf "  ... %d repeated port rows hidden by PORT_LIMIT\n", NR - limit
                    }
                }'
        fi

        echo "Single-hit ports folded: $single_ports ports / $single_hits hits, traffic unknown"
    fi

    rm -f "$tmp_ports"
}

report_top_ip_details() {
    csv_file="$1"
    start_local="$2"
    end_local="$3"

    len_seen="$(awk -F',' 'NF>=5 && $5 ~ /^[0-9]+$/ {seen=1} END {print seen+0}' "$csv_file")"

    line
    echo "TOP ${TOP_N} IP DETAILS: PORTS + ACTIVE TIME RANGE ${REPORT_TZ_LABEL}"
    line
    echo "Range     : $(format_range_time "$start_local") -> $(format_range_time "$end_local") ${REPORT_TZ_LABEL}"
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
        first_epoch="$(awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' "$csv_file" | sort -n | head -n 1)"
        last_epoch="$(awk -F',' -v ip="$ip" 'NF>=4 && $3==ip {print $1}' "$csv_file" | sort -n | tail -n 1)"

        echo ""
        echo "IP: $ip"
        echo "Hits: $hits"

        if [ "$len_seen" -eq 1 ]; then
            ip_bytes="$(awk -F',' -v ip="$ip" 'NF>=5 && $3==ip && $5 ~ /^[0-9]+$/ {sum+=$5} END {print sum+0}' "$csv_file")"
            echo "Logged traffic: $(human_bytes "$ip_bytes") ($ip_bytes bytes)"
        else
            echo "Logged traffic: unknown"
        fi

        echo "First seen: $(format_epoch "$first_epoch") ${REPORT_TZ_LABEL}"
        echo "Last seen : $(format_epoch "$last_epoch") ${REPORT_TZ_LABEL}"
        echo "Ports:"

        emit_port_rows "$csv_file" "$ip" "$len_seen"
    done
}

run_report() {
    title="$1"
    start_local="$2"
    end_local="$3"

    clear || true

    tmp_raw="$(mktemp)"
    tmp_csv="$(mktemp)"
    trap 'rm -f "$tmp_raw" "$tmp_csv"' EXIT

    get_journal_logs "$start_local" "$end_local" > "$tmp_raw"
    extract_logs_csv < "$tmp_raw" > "$tmp_csv"

    if [ ! -s "$tmp_csv" ]; then
        line
        echo "NO CONNECTION LOGS FOUND"
        line
        echo "Report     : $title"
        echo "Range      : $(format_range_time "$start_local") -> $(format_range_time "$end_local") ${REPORT_TZ_LABEL}"
        echo "Log prefix : $LOG_PREFIX"
        echo ""
        echo "Try:"
        echo "  journalctl -k -o short-unix --no-pager | grep 'nft-new:' | tail"
        echo "  nft list ruleset | grep log"
        return
    fi

    report_top_ip_details "$tmp_csv" "$start_local" "$end_local"
}

daily_report() {
    start="$(TZ="$REPORT_TZ" date '+%Y-%m-%d 00:00:00')"
    end="$(TZ="$REPORT_TZ" date '+%Y-%m-%d 23:59:59')"
    run_report "DAILY NFT CONNECTION REPORT" "$start" "$end"
}

weekly_report() {
    start="$(TZ="$REPORT_TZ" date -d '6 days ago' '+%Y-%m-%d 00:00:00')"
    end="$(TZ="$REPORT_TZ" date '+%Y-%m-%d 23:59:59')"
    run_report "WEEKLY NFT CONNECTION REPORT" "$start" "$end"
}

custom_report() {
    echo "Input start date in ${REPORT_TZ_LABEL}, example: 2026-06-22"
    read -r -p "Start date: " s

    echo "Input end date in ${REPORT_TZ_LABEL}, example: 2026-06-22"
    read -r -p "End date: " e

    if ! TZ="$REPORT_TZ" date -d "$s" >/dev/null 2>&1 || ! TZ="$REPORT_TZ" date -d "$e" >/dev/null 2>&1; then
        echo "[ERROR] invalid date"
        return
    fi

    start="$s 00:00:00"
    end="$e 23:59:59"
    run_report "CUSTOM NFT CONNECTION REPORT" "$start" "$end"
}

print_recent_logs_utc8() {
    journalctl -k -o short-unix --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" \
        | tail -n 10 \
        | while IFS= read -r log_line; do
            epoch_part="${log_line%% *}"
            rest_part="${log_line#* }"
            epoch_sec="${epoch_part%%.*}"
            if printf "%s" "$epoch_sec" | grep -Eq '^[0-9]+$'; then
                printf "%s %s %s\n" "$(format_epoch "$epoch_sec")" "$REPORT_TZ_LABEL" "$rest_part"
            else
                printf "%s\n" "$log_line"
            fi
        done
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
    echo "[recent logs converted to ${REPORT_TZ_LABEL}]"
    print_recent_logs_utc8 || true
}

menu() {
    while true; do
        echo ""
        echo "===== NFT CONNECTION REPORT TOP10 UTC+8 ====="
        echo "1) Daily report"
        echo "2) Weekly report"
        echo "3) Custom date range"
        echo "4) Status check"
        echo "5) Help"
        echo "6) Exit"
        echo "============================================="
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











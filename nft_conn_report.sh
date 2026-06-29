#!/usr/bin/env bash

set -e

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"

# Report/output timezone. Asia/Shanghai and Asia/Singapore are both UTC+8.
REPORT_TZ="${REPORT_TZ:-Asia/Shanghai}"
REPORT_TZ_LABEL="${REPORT_TZ_LABEL:-}"

LOG_PREFIX="${LOG_PREFIX:-nft-new:}"
TOP_N="${TOP_N:-10}"
PORT_LIMIT="${PORT_LIMIT:-0}"
PORT_EXCLUDE_LIST="${PORT_EXCLUDE_LIST:-}"
# Enable ip-api.com GeoIP lookup by default. Set IP_API_GEO=0 to disable.
IP_API_GEO="${IP_API_GEO:-1}"
IP_API_CONNECT_TIMEOUT="${IP_API_CONNECT_TIMEOUT:-1}"
IP_API_MAX_TIME="${IP_API_MAX_TIME:-2}"

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

derive_report_tz_label() {
    offset="$(TZ="$REPORT_TZ" date '+%z')"
    sign="${offset:0:1}"
    hh="${offset:1:2}"
    mm="${offset:3:2}"
    hh_num="$((10#$hh))"

    if [ "$mm" = "00" ]; then
        REPORT_TZ_LABEL="UTC${sign}${hh_num}"
    else
        REPORT_TZ_LABEL="UTC${sign}${hh_num}:${mm}"
    fi
}

usage() {
    cat <<EOF_USAGE
Usage:
  bash "$SCRIPT_PATH" daily
  bash "$SCRIPT_PATH" weekly
  bash "$SCRIPT_PATH" custom
  bash "$SCRIPT_PATH" status
  bash "$SCRIPT_PATH" raw

Optional environment variables:
  LOG_PREFIX='nft-new:' bash "$SCRIPT_PATH" daily
  TOP_N=20 bash "$SCRIPT_PATH" daily
  PORT_LIMIT=20 bash "$SCRIPT_PATH" daily
  IP_API_GEO=0 bash "$SCRIPT_PATH" daily
  IP_API_CONNECT_TIMEOUT=1 IP_API_MAX_TIME=2 bash "$SCRIPT_PATH" daily
  REPORT_TZ=Asia/Singapore bash "$SCRIPT_PATH" daily
  REPORT_TZ=Asia/Tokyo REPORT_TZ_LABEL=UTC+9 bash "$SCRIPT_PATH" daily

Defaults:
  TOP_N=10
  PORT_LIMIT=0        Show all repeated ports under each top IP.
                      Ports with HITS=1 are always folded and not listed.
  REPORT_TZ=Asia/Shanghai
  REPORT_TZ_LABEL is auto-derived from REPORT_TZ unless explicitly set
  IP_API_GEO=1        Show Geo line for each TOP IP using ip-api.com.
                      Set IP_API_GEO=0 to disable.
  IP_API_CONNECT_TIMEOUT=1
  IP_API_MAX_TIME=2   Keep API failures/timeouts from blocking the report too long.

Timezone note:
  This script converts the requested report range to Unix epoch seconds in REPORT_TZ.
  It filters journal entries by epoch, then displays all timestamps in REPORT_TZ.
  This avoids problems when the server is using UTC, Europe/Rome, Asia/Singapore,
  Asia/Tokyo, or another timezone.

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

    if [ -z "$REPORT_TZ_LABEL" ]; then
        derive_report_tz_label
    fi

    if ! printf '%s' "$TOP_N" | grep -Eq '^[0-9]+$' || [ "$TOP_N" -lt 1 ]; then
        echo "[ERROR] TOP_N must be a positive integer"
        exit 1
    fi

    if ! printf '%s' "$PORT_LIMIT" | grep -Eq '^[0-9]+$'; then
        echo "[ERROR] PORT_LIMIT must be 0 or a positive integer"
        exit 1
    fi
}

to_epoch() {
    local_time="$1"
    TZ="$REPORT_TZ" date -d "$local_time" '+%s'
}

format_epoch() {
    epoch="$1"
    TZ="$REPORT_TZ" date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S%z'
}

format_epoch_range() {
    epoch="$1"
    TZ="$REPORT_TZ" date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %z'
}

filter_epoch_range() {
    start_epoch="$1"
    end_epoch="$2"

    awk -v start="$start_epoch" -v end="$end_epoch" '
    {
        epoch=$1
        sub(/\..*/, "", epoch)
        if (epoch ~ /^[0-9]+$/ && epoch >= start && epoch <= end) {
            print $0
        }
    }'
}

journal_query_fast() {
    start_epoch="$1"
    end_epoch="$2"

    # Convert epoch to the server local timezone for journalctl arguments.
    # journalctl parses --since/--until in the server local timezone, so this
    # avoids passing "+0800" or other offset strings that some systems reject.
    since_arg="$(date -d "@$start_epoch" '+%Y-%m-%d %H:%M:%S')"
    until_arg="$(date -d "@$end_epoch" '+%Y-%m-%d %H:%M:%S')"

    journalctl -k -o short-unix --since "$since_arg" --until "$until_arg" --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" \
        | filter_epoch_range "$start_epoch" "$end_epoch" || true
}

journal_query_fallback() {
    start_epoch="$1"
    end_epoch="$2"

    # Fallback intentionally does not pass timezone strings to journalctl.
    # It reads kernel journal lines with epoch timestamps, then filters by epoch itself.
    journalctl -k -o short-unix --no-pager 2>/dev/null \
        | grep -F "$LOG_PREFIX" \
        | filter_epoch_range "$start_epoch" "$end_epoch" || true
}

get_journal_logs() {
    start_epoch="$1"
    end_epoch="$2"
    out_file="$3"

    tmp_fast="$(mktemp)"
    journal_query_fast "$start_epoch" "$end_epoch" > "$tmp_fast"

    if [ -s "$tmp_fast" ]; then
        cat "$tmp_fast" > "$out_file"
        rm -f "$tmp_fast"
        return
    fi

    rm -f "$tmp_fast"
    journal_query_fallback "$start_epoch" "$end_epoch" > "$out_file"
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

filter_csv_excluded_ports() {
    csv_file="$1"
    exclude_ports="$2"

    if [ -z "$exclude_ports" ]; then
        cat "$csv_file"
        return
    fi

    awk -F',' -v exclude_ports="$exclude_ports" '
    BEGIN {
        split(exclude_ports, p, " ")
        for (i in p) {
            if (p[i] != "") {
                excluded[p[i]]=1
            }
        }
    }
    NF>=4 {
        if (!($4 in excluded)) {
            print $0
        }
    }' "$csv_file"
}

show_port_filter_menu() {
    while true; do
        echo ""
        echo "Select port filter:"
        echo "1) All ports TOP${TOP_N}"
        echo "2) Exclude 443 TOP${TOP_N}"
        echo "3) Exclude 443, 22 TOP${TOP_N}"
        echo "4) Exclude 443, 22, 80 TOP${TOP_N}"
        echo "5) Exclude 443, 22, 80, 81 TOP${TOP_N}"
        echo "================================================"
        read -r -p "Select: " pf

        case "$pf" in
            1)
                PORT_EXCLUDE_LIST=""
                break
                ;;
            2)
                PORT_EXCLUDE_LIST="443"
                break
                ;;
            3)
                PORT_EXCLUDE_LIST="443 22"
                break
                ;;
            4)
                PORT_EXCLUDE_LIST="443 22 80"
                break
                ;;
            5)
                PORT_EXCLUDE_LIST="443 22 80 81"
                break
                ;;
            *)
                echo "invalid"
                ;;
        esac
    done
}


json_get_string() {
    json_text="$1"
    key_name="$2"

    printf '%s\n' "$json_text" \
        | sed -n 's/.*"'"$key_name"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' \
        | head -n 1
}

lookup_ip_geo() {
    ip="$1"

    if [ "${IP_API_GEO:-1}" = "0" ]; then
        return
    fi

    if ! has_cmd curl; then
        echo "Geo: unknown"
        return
    fi

    api_url="http://ip-api.com/json/${ip}?lang=zh-CN&fields=status,message,country,regionName,city,district,isp,org,as,query"
    api_resp="$(curl -fsS --connect-timeout "$IP_API_CONNECT_TIMEOUT" --max-time "$IP_API_MAX_TIME" "$api_url" 2>/dev/null || true)"

    if [ -z "$api_resp" ]; then
        echo "Geo: unknown"
        return
    fi

    status="$(json_get_string "$api_resp" "status")"
    if [ "$status" != "success" ]; then
        echo "Geo: unknown"
        return
    fi

    country="$(json_get_string "$api_resp" "country")"
    region="$(json_get_string "$api_resp" "regionName")"
    city="$(json_get_string "$api_resp" "city")"
    district="$(json_get_string "$api_resp" "district")"
    isp="$(json_get_string "$api_resp" "isp")"
    org="$(json_get_string "$api_resp" "org")"

    geo_text=""
    for part in "$country" "$region" "$city" "$district"; do
        if [ -n "$part" ] && [ "$part" != "null" ]; then
            case " $geo_text " in
                *" $part "*) ;;
                *) geo_text="${geo_text:+$geo_text }$part" ;;
            esac
        fi
    done

    net_text=""
    for part in "$isp" "$org"; do
        if [ -n "$part" ] && [ "$part" != "null" ]; then
            case " $net_text " in
                *" $part "*) ;;
                *) net_text="${net_text:+$net_text / }$part" ;;
            esac
        fi
    done

    if [ -z "$geo_text" ]; then
        geo_text="unknown"
    fi

    if [ -n "$net_text" ]; then
        echo "Geo: $geo_text | ISP/ORG: $net_text"
    else
        echo "Geo: $geo_text"
    fi
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
                    total=0
                    printf "  %-8s %-14s %s\n", "HITS", "TRAFFIC", "PROTO/PORT"
                }
                {
                    total++
                    if (limit == 0 || shown < limit) {
                        shown++
                        printf "  %-8s %-14s %s\n", $1, human($2), $3
                    }
                }
                END {
                    if (limit > 0 && total > limit) {
                        printf "  ... %d repeated port rows hidden by PORT_LIMIT\n", total - limit
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
                    total=0
                    printf "  %-8s %s\n", "HITS", "PROTO/PORT"
                }
                {
                    total++
                    if (limit == 0 || shown < limit) {
                        shown++
                        printf "  %-8s %s\n", $1, $2
                    }
                }
                END {
                    if (limit > 0 && total > limit) {
                        printf "  ... %d repeated port rows hidden by PORT_LIMIT\n", total - limit
                    }
                }'
        fi

        echo "Single-hit ports folded: $single_ports ports / $single_hits hits, traffic unknown"
    fi

    rm -f "$tmp_ports"
}

report_top_ip_details() {
    csv_file="$1"
    start_epoch="$2"
    end_epoch="$3"

    row_count="$(awk -F',' 'NF>=4 {c++} END {print c+0}' "$csv_file")"
    len_rows="$(awk -F',' 'NF>=5 && $5 ~ /^[0-9]+$/ {c++} END {print c+0}' "$csv_file")"
    if [ "$len_rows" -gt 0 ]; then
        len_seen=1
    else
        len_seen=0
    fi

    line
    echo "TOP ${TOP_N} IP DETAILS: PORTS + ACTIVE TIME RANGE ${REPORT_TZ_LABEL}"
    line
    echo "Range     : $(format_epoch_range "$start_epoch") -> $(format_epoch_range "$end_epoch") ${REPORT_TZ_LABEL}"
    echo "Log prefix: $LOG_PREFIX"
    if [ -z "$PORT_EXCLUDE_LIST" ]; then
        echo "Port filter: all ports"
    else
        echo "Port filter: exclude DPT ports = $PORT_EXCLUDE_LIST"
    fi

    if [ "$len_seen" -eq 1 ]; then
        total_bytes="$(awk -F',' 'NF>=5 && $5 ~ /^[0-9]+$/ {sum+=$5} END {print sum+0}' "$csv_file")"
        echo "Traffic   : logged packet length total = $(human_bytes "$total_bytes") ($total_bytes bytes)"
        if [ "$len_rows" -lt "$row_count" ]; then
            missing_len_rows="$((row_count - len_rows))"
            echo "Traffic warning: $missing_len_rows matched rows have no LEN= field; traffic is partial"
        fi
    else
        echo "Traffic   : unknown, no LEN= field found in matched logs"
    fi

    top_ips="$(awk -F',' 'NF>=4 {count[$3]++} END {for (ip in count) print count[ip], ip}' "$csv_file" \
        | sort -k1,1nr -k2,2 \
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
        lookup_ip_geo "$ip"
        echo "Hits: $hits"

        if [ "$len_seen" -eq 1 ]; then
            ip_bytes="$(awk -F',' -v ip="$ip" 'NF>=5 && $3==ip && $5 ~ /^[0-9]+$/ {sum+=$5} END {print sum+0}' "$csv_file")"
            ip_len_rows="$(awk -F',' -v ip="$ip" 'NF>=5 && $3==ip && $5 ~ /^[0-9]+$/ {c++} END {print c+0}' "$csv_file")"
            if [ "$ip_len_rows" -lt "$hits" ]; then
                ip_missing_len_rows="$((hits - ip_len_rows))"
                echo "Logged traffic: $(human_bytes "$ip_bytes") ($ip_bytes bytes, partial; $ip_missing_len_rows hits without LEN=)"
            else
                echo "Logged traffic: $(human_bytes "$ip_bytes") ($ip_bytes bytes)"
            fi
        else
            echo "Logged traffic: unknown"
        fi

        echo "First seen: $(format_epoch "$first_epoch") ${REPORT_TZ_LABEL}"
        echo "Last seen : $(format_epoch "$last_epoch") ${REPORT_TZ_LABEL}"
        echo "Ports:"

        emit_port_rows "$csv_file" "$ip" "$len_seen"
    done
}

show_no_data_help() {
    title="$1"
    start_epoch="$2"
    end_epoch="$3"

    line
    echo "NO CONNECTION LOGS FOUND"
    line
    echo "Report     : $title"
    echo "Range      : $(format_epoch_range "$start_epoch") -> $(format_epoch_range "$end_epoch") ${REPORT_TZ_LABEL}"
    echo "Epoch range: $start_epoch -> $end_epoch"
    echo "Log prefix : $LOG_PREFIX"
    if [ -z "$PORT_EXCLUDE_LIST" ]; then
        echo "Port filter: all ports"
    else
        echo "Port filter: exclude DPT ports = $PORT_EXCLUDE_LIST"
    fi
    echo ""
    echo "Try:"
    echo "  journalctl -k -o short-unix --no-pager | grep -F '$LOG_PREFIX' | tail"
    echo "  nft list ruleset | grep log"
    echo ""
    echo "If the first command shows rows but this report is empty, run:"
    echo "  REPORT_TZ=Asia/Shanghai bash \"$SCRIPT_PATH\" status"
}

run_report() {
    title="$1"
    start_local="$2"
    end_local="$3"

    start_epoch="$(to_epoch "$start_local")"
    end_epoch="$(to_epoch "$end_local")"

    if [ -t 1 ]; then
        clear || true
    fi

    tmp_raw="$(mktemp)"
    tmp_csv_all="$(mktemp)"
    tmp_csv="$(mktemp)"

    get_journal_logs "$start_epoch" "$end_epoch" "$tmp_raw"
    extract_logs_csv < "$tmp_raw" > "$tmp_csv_all"
    filter_csv_excluded_ports "$tmp_csv_all" "$PORT_EXCLUDE_LIST" > "$tmp_csv"

    if [ ! -s "$tmp_csv" ]; then
        show_no_data_help "$title" "$start_epoch" "$end_epoch"
        rm -f "$tmp_raw" "$tmp_csv_all" "$tmp_csv"
        return
    fi

    report_top_ip_details "$tmp_csv" "$start_epoch" "$end_epoch"
    rm -f "$tmp_raw" "$tmp_csv_all" "$tmp_csv"
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

    start_epoch="$(to_epoch "$start")"
    end_epoch="$(to_epoch "$end")"
    if [ "$start_epoch" -gt "$end_epoch" ]; then
        echo "[ERROR] start date must be before or equal to end date"
        return
    fi

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

raw_logs_tail() {
    line
    echo "RAW NFT LOGS TAIL, CONVERTED TO ${REPORT_TZ_LABEL}"
    line
    print_recent_logs_utc8 || true
}

check_status() {
    line
    echo "STATUS CHECK"
    line

    now_epoch="$(date '+%s')"
    echo ""
    echo "[time]"
    echo "System local : $(date '+%Y-%m-%d %H:%M:%S %z %Z')"
    echo "Report TZ    : $(format_epoch "$now_epoch") ${REPORT_TZ_LABEL}"
    echo "Epoch now    : $now_epoch"

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
        echo "===== NFT CONNECTION REPORT TOP${TOP_N} ${REPORT_TZ_LABEL} V2 ====="
        echo "1) Daily report"
        echo "2) Weekly report"
        echo "3) Custom date range"
        echo "4) Show recent raw nft logs"
        echo "5) Status check"
        echo "6) Help"
        echo "7) Exit"
        echo "================================================"
        read -r -p "Select: " c

        case "$c" in
            1)
                show_port_filter_menu
                daily_report
                pause
                ;;
            2)
                show_port_filter_menu
                weekly_report
                pause
                ;;
            3)
                PORT_EXCLUDE_LIST=""
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

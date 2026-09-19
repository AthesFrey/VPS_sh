#!/usr/bin/env bash

# Unified nftables firewall manager script.
# Default target: one persistent config file and one nft table:
#   /etc/nftables.conf -> administrator-owned config plus an include
#   /etc/nftables.conf.nftfw -> table inet filter managed by this script
#
# Main design:
# - Normal Apply writes only the managed fragment and loads it through a
#   temporary transaction that replaces only the managed table.
# - The main config is preserved and receives one idempotent include for the fragment.
# - Normal Apply does NOT use `flush ruleset`; it replaces only the managed table.
# - Forward chain keeps policy drop but allows Docker published DNAT and container outbound traffic.
# - Emergency Initialize also replaces only the managed table.
# - Port lists are stored in /etc/nft_ports_tcp.list and /etc/nft_ports_udp.list.
# - Baselines use the detected SSH listener (22 or 26), plus 80/443; UDP is empty.

set -e

VERSION="3.1hotfix"

SCRIPT_PATH="${0:-firewall_nft_manager.sh}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
if [ -z "$SCRIPT_NAME" ]; then
    SCRIPT_NAME="firewall_nft_manager.sh"
fi

BACKUP_DIR="${BACKUP_DIR:-/etc/nftables.backup}"
TCP_FILE="${TCP_FILE:-/etc/nft_ports_tcp.list}"
UDP_FILE="${UDP_FILE:-/etc/nft_ports_udp.list}"
NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"
NFT_MANAGED_CONF="${NFT_MANAGED_CONF:-${NFT_CONF}.nftfw}"
NFT_INCLUDE_LINE="include \"$NFT_MANAGED_CONF\""

# Generated rules require the inet family (both IPv4 and IPv6).
MGR_FAMILY="${MGR_FAMILY:-inet}"
MGR_TABLE="${MGR_TABLE:-filter}"
ALLOW_CUSTOM_TARGET="${ALLOW_CUSTOM_TARGET:-0}"

LOG_PREFIX_NFT="${LOG_PREFIX_NFT:-nft-new: }"
JOURNAL_LIMIT="${JOURNAL_LIMIT:-100M}"
JOURNAL_DROPIN_DIR="${JOURNAL_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_FILE:-$JOURNAL_DROPIN_DIR/99-nft-log-size-limit.conf}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/nft-kernel-logs}"
LOGROTATE_MAIN_CONF="${LOGROTATE_MAIN_CONF:-/etc/logrotate.conf}"

SSH_OLD_PORT=22
SSH_NEW_PORT=26
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
SSHD_DROPIN_FILE="${SSHD_DROPIN_FILE:-$SSHD_DROPIN_DIR/99-nftfw-port.conf}"
FAIL2BAN_CONFIG_DIR="${FAIL2BAN_CONFIG_DIR:-/etc/fail2ban}"
FAIL2BAN_JAIL_FILE="${FAIL2BAN_JAIL_FILE:-$FAIL2BAN_CONFIG_DIR/jail.d/nftfw-sshd.local}"
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-1h}"
FAIL2BAN_FINDTIME="${FAIL2BAN_FINDTIME:-10m}"
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-5}"

NFT_BIN=""

# Log storage limits are not changed during Apply by default.
AUTO_CONFIGURE_LOG_LIMIT="${AUTO_CONFIGURE_LOG_LIMIT:-0}"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

nft_cmd() {
    "$NFT_BIN" "$@"
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
    elif [ -x /usr/sbin/nft ]; then
        NFT_BIN=/usr/sbin/nft
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
    elif [ -x /usr/sbin/nft ]; then
        NFT_BIN=/usr/sbin/nft
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

validate_identifier() {
    local name value
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
            echo "[ERROR] This version requires MGR_FAMILY=inet."
            echo "[ERROR] Current MGR_FAMILY: $MGR_FAMILY"
            echo "[ERROR] Reason: the generated config contains both IPv4 and IPv6 rules in one table."
            return 1
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
    local ssh_port
    if [ ! -s "$TCP_FILE" ]; then
        ssh_port="$(detect_baseline_ssh_port)" || return 1
        write_csv_file "$TCP_FILE" "$ssh_port,80,443" || return 1
        echo "[INFO] Initialized TCP baseline: $ssh_port,80,443"
    fi
    if [ ! -e "$UDP_FILE" ]; then
        write_csv_file "$UDP_FILE" "" || return 1
    fi
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
    local item start end
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
    local item
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
    local item
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

csv_canonicalize() (
    local csv="$1" dir item
    local -a items
    dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$dir"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    csv="$(normalize_text "$csv")" || return 1
    : > "$dir/items" || return 1
    IFS=',' read -r -a items <<< "$csv"
    # Quoted array iteration prevents a wildcard from importing local filenames.
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        if valid_item "$item"; then
            printf '%s %s\n' "$(item_start "$item")" "$(item_end "$item")" >> "$dir/items" || return 1
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi
    done
    sort -n -k1,1 -k2,2 "$dir/items" > "$dir/sorted" || return 1
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
    ' "$dir/sorted"

)

csv_from_file() {
    local file text
    file="$1"

    if [ ! -s "$file" ]; then
        echo ""
        return
    fi

    text="$(cat -- "$file")" || return 1
    csv_canonicalize "$text"
}

csv_from_text() {
    local text
    text="$1"
    csv_canonicalize "$text"
}

write_csv_file() {
    local file csv tmp rc=0
    file="$1"
    csv="$2"

    csv="$(csv_canonicalize "$csv")" || return 1
    tmp="$(mktemp)" || return 1
    if [ -n "$csv" ]; then
        printf '%s\n' "$csv" | tr ',' '\n' > "$tmp" || rc=1
    fi
    if [ "$rc" = 0 ]; then
        atomic_copy "$tmp" "$file" || rc=1
    fi
    rm -f -- "$tmp"
    return "$rc"
}

nft_set_from_csv() {
    local csv
    csv="$1"
    printf "%s" "$csv" | sed 's/,/, /g'
}

csv_contains_port() {
    local csv port OLDIFS item s e
    csv="$1"
    port="$2"

    csv="$(csv_canonicalize "$csv")" || return 1
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
    local current_csv remove_csv
    current_csv="$(csv_canonicalize "$1")" || return 1
    remove_csv="$(csv_canonicalize "$2")" || return 1

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

configure_journal_limit() (
    local dir committed=0 restart_attempted=0
    ensure_systemctl || return 1
    if ! has_cmd journalctl; then
        echo "[ERROR] journalctl not found; log limits were not changed." >&2
        return 1
    fi
    if [[ ! "$JOURNAL_LIMIT" =~ ^[1-9][0-9]*[KMG]?$ ]]; then
        echo "[ERROR] JOURNAL_LIMIT must be positive bytes or a size such as 100M (K/M/G)." >&2
        return 1
    fi
    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/logs.XXXXXX")" || return 1
    snapshot_file "$JOURNAL_DROPIN_FILE" "$dir/journal.conf" || return 1
    snapshot_file "$LOGROTATE_FILE" "$dir/logrotate.conf" || return 1
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_log_config() {
        local rc="$?" failed=0
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_file "$dir/journal.conf" "$JOURNAL_DROPIN_FILE" || failed=1
            restore_file "$dir/logrotate.conf" "$LOGROTATE_FILE" || failed=1
            if [ "$restart_attempted" = 1 ]; then
                systemctl restart systemd-journald || failed=1
            fi
            echo "[ERROR] Log limit setup failed; previous configuration restored if possible. Backups: $dir" >&2
            [ "$failed" = 0 ] || echo "[ERROR] Log configuration rollback incomplete." >&2
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_log_config EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    echo "[+] Configuring journald size limit: $JOURNAL_LIMIT"
    mkdir -p "$(dirname "$JOURNAL_DROPIN_FILE")" || return 1
    cat > "$dir/journal.new" <<EOF_JOURNAL || return 1
[Journal]
SystemMaxUse=$JOURNAL_LIMIT
RuntimeMaxUse=$JOURNAL_LIMIT
SystemMaxFileSize=$JOURNAL_LIMIT
RuntimeMaxFileSize=$JOURNAL_LIMIT
EOF_JOURNAL
    atomic_copy "$dir/journal.new" "$JOURNAL_DROPIN_FILE" || return 1
    configure_logrotate_limit "$dir/logrotate.new" || return 1
    restart_attempted=1
    if ! systemctl restart systemd-journald; then
        echo "[ERROR] journald restart failed." >&2
        return 1
    fi
    if ! journalctl --rotate || ! journalctl --vacuum-size="$JOURNAL_LIMIT"; then
        echo "[ERROR] Journal rotation/cleanup failed; already removed archives cannot be restored." >&2
        return 1
    fi
    committed=1
    echo "[OK] Log storage limit configured."
)

configure_logrotate_limit() {
    local tmp="$1" size="${JOURNAL_LIMIT/K/k}" logrotate_bin validation_conf
    if [ ! -d "$(dirname "$LOGROTATE_FILE")" ]; then
        echo "[INFO] logrotate directory is absent; configuring journald only."
        return 0
    fi
    logrotate_bin="$(command -v logrotate || true)"
    if [ -z "$logrotate_bin" ] && [ -x /usr/sbin/logrotate ]; then
        logrotate_bin=/usr/sbin/logrotate
    fi
    if [ -z "$logrotate_bin" ]; then
        echo "[INFO] logrotate is absent; configuring journald only."
        return 0
    fi
    cat > "$tmp" <<EOF_LOGROTATE || return 1
/var/log/kern.log /var/log/syslog /var/log/messages {
    size $size
    rotate 1
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF_LOGROTATE
    atomic_copy "$tmp" "$LOGROTATE_FILE" || return 1
    validation_conf="$LOGROTATE_FILE"
    if [ -f "$LOGROTATE_MAIN_CONF" ]; then
        validation_conf="$LOGROTATE_MAIN_CONF"
    fi
    # --debug performs no rotations or state writes. Check the entire config to
    # catch duplicate syslog/kern.log entries owned by an existing rsyslog rule.
    if ! "$logrotate_bin" --debug --state /dev/null "$validation_conf" > "$tmp.check" 2>&1; then
        echo "[ERROR] logrotate validation failed (including possible duplicate log entries)." >&2
        cat "$tmp.check" >&2
        return 1
    fi
}

foreign_tables() {
    if [ -z "$NFT_BIN" ]; then
        return 0
    fi

    nft_cmd list tables 2>/dev/null \
        | awk -v family="$MGR_FAMILY" -v table="$MGR_TABLE" '
            $1 == "table" {
                if (!($2 == family && $3 == table)) {
                    print $0
                }
            }
        '
}

write_unified_nft_conf() {
    local out tcp_ports udp_ports tcp_set udp_set log_prefix_escaped
    out="$1"
    if [ "$#" -ge 2 ]; then
        tcp_ports="$2"
    else
        tcp_ports="$(csv_from_file "$TCP_FILE")" || return 1
    fi
    udp_ports="$(csv_from_file "$UDP_FILE")" || return 1
    tcp_set="$(nft_set_from_csv "$tcp_ports")"
    udp_set="$(nft_set_from_csv "$udp_ports")"
    log_prefix_escaped="$(nft_escape_string "$LOG_PREFIX_NFT")"

    cat > "$out" <<EOF_NFT || return 1
#!$NFT_BIN -f

# Generated by $SCRIPT_NAME
# Managed fragment: $NFT_MANAGED_CONF
# Main config (preserved): $NFT_CONF
# Managed table: $MGR_FAMILY $MGR_TABLE
EOF_NFT

    cat >> "$out" <<EOF_NFT || return 1
table $MGR_FAMILY $MGR_TABLE {
    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept comment "nftfw: loopback"
        ct state established,related accept comment "nftfw: established related"
        ct state invalid drop comment "nftfw: invalid"
EOF_NFT

    if [ -n "$tcp_ports" ]; then
        printf '\n        ct state new tcp dport { %s } log prefix "%s" level info comment "nftfw: log managed tcp"\n' "$tcp_set" "$log_prefix_escaped" >> "$out" || return 1
        printf '        tcp dport { %s } accept comment "nftfw: accept managed tcp"\n' "$tcp_set" >> "$out" || return 1
    fi

    if [ -n "$udp_ports" ]; then
        printf '\n        ct state new udp dport { %s } log prefix "%s" level info comment "nftfw: log managed udp"\n' "$udp_set" "$log_prefix_escaped" >> "$out" || return 1
        printf '        udp dport { %s } accept comment "nftfw: accept managed udp"\n' "$udp_set" >> "$out" || return 1
    fi

    cat >> "$out" <<EOF_NFT || return 1

        ip protocol icmp accept comment "nftfw: icmp"
        meta l4proto ipv6-icmp accept comment "nftfw: icmpv6"

        ct state new log prefix "$log_prefix_escaped" level info comment "nftfw: log unmanaged new"
        counter drop comment "nftfw: final input drop"
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept comment "nftfw: forward established related"
        ct state invalid drop comment "nftfw: forward invalid"

        # Docker compatibility for published ports and container outbound traffic.
        # Docker bridge IPv4 subnets normally live inside 172.16.0.0/12,
        # for example default bridge 172.17.0.0/16 and user bridges 172.18.0.0/16+.
        # These rules prevent this manager's forward policy drop from blocking Docker DNAT.
        ct status dnat ip daddr 172.16.0.0/12 accept comment "nftfw: allow docker published dnat"
        ip saddr 172.16.0.0/12 accept comment "nftfw: allow docker outbound forward"

        counter drop comment "nftfw: forward drop"
    }

    chain output {
        type filter hook output priority 0; policy accept;
        accept comment "nftfw: output accept"
    }
}
EOF_NFT
}

write_nft_apply_transaction() {
    local out="$1" fragment="$2" fragment_escaped
    fragment_escaped="$(nft_escape_string "$fragment")" || return 1
    cat > "$out" <<EOF_NFT || return 1
#!$NFT_BIN -f

# Generated by $SCRIPT_NAME
# Replace only the managed table, then load its declarative fragment.
add table $MGR_FAMILY $MGR_TABLE
delete table $MGR_FAMILY $MGR_TABLE
include "$fragment_escaped"
EOF_NFT
}

# Snapshots include a marker for absent files, so rollback also removes new files.
snapshot_file() {
    local src="$1" dst="$2"
    if [ -e "$src" ] || [ -L "$src" ]; then
        cp -a -- "$src" "$dst"
    else
        : > "$dst.missing"
    fi
}

restore_file() {
    local snapshot="$1" dst="$2"
    if [ -e "$snapshot" ] || [ -L "$snapshot" ]; then
        mkdir -p -- "$(dirname "$dst")" || return 1
        cp -a --remove-destination -- "$snapshot" "$dst"
    elif [ -f "$snapshot.missing" ]; then
        rm -f -- "$dst"
    else
        echo "[ERROR] Missing backup: $snapshot" >&2
        return 1
    fi
}

atomic_copy() {
    local src="$1" dst="$2" tmp
    tmp="$(mktemp "${dst}.nftfw.XXXXXX")" || return 1
    if ! cat -- "$src" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if [ -e "$dst" ]; then
        if ! chmod --reference="$dst" "$tmp" || ! chown --reference="$dst" "$tmp"; then
            rm -f -- "$tmp"
            return 1
        fi
    else
        chmod 644 "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    mv -f -- "$tmp" "$dst" || { rm -f -- "$tmp"; return 1; }
}

# Keep the administrator's main nftables configuration intact and add exactly
# one include for the fragment owned by this script.  Older 3.0 files were
# generated as a complete managed configuration; when that marker is present,
# remove only the old managed table block before adding the fragment include.
ensure_managed_include() {
    local tmp add_line table_line
    tmp="$(mktemp)" || return 1
    add_line="add table $MGR_FAMILY $MGR_TABLE"
    table_line="table $MGR_FAMILY $MGR_TABLE {"
    mkdir -p -- "$(dirname "$NFT_CONF")" || { rm -f -- "$tmp"; return 1; }
    if [ -e "$NFT_CONF" ]; then
        awk -v include_path="$NFT_MANAGED_CONF" -v add_line="$add_line" -v table_line="$table_line" '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }
            function brace_delta(s, opens, closes) {
                opens = gsub(/\{/, "{", s)
                closes = gsub(/\}/, "}", s)
                return opens - closes
            }
            {
                line = trim($0)
                if (line ~ /^include[[:space:]]+\"/) {
                    candidate = line
                    sub(/^include[[:space:]]+\"/, "", candidate)
                    sub(/\"[[:space:]]*;?[[:space:]]*(#.*)?$/, "", candidate)
                    if (candidate == include_path) {
                        if (!include_seen) {
                            print
                            include_seen = 1
                        }
                        next
                    }
                }

                if (line ~ /^# Generated by .*firewall_nft_manager[.]sh[[:space:]]*$/)
                    legacy = 1

                if (legacy && !skipping && line == add_line) {
                    skipping = 1
                    started = 0
                    depth = 0
                    next
                }

                if (skipping) {
                    if (line == table_line)
                        started = 1
                    if (started) {
                        depth += brace_delta($0)
                        if (depth <= 0)
                            skipping = 0
                    }
                    next
                }
                print
            }
        ' "$NFT_CONF" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    if ! awk -v include_path="$NFT_MANAGED_CONF" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            line = trim($0)
            if (line ~ /^include[[:space:]]+\"/) {
                candidate = line
                sub(/^include[[:space:]]+\"/, "", candidate)
                sub(/\"[[:space:]]*;?[[:space:]]*(#.*)?$/, "", candidate)
                if (candidate == include_path)
                    found = 1
            }
        }
        END { exit !found }
    ' "$tmp" >/dev/null; then
        if [ -s "$tmp" ]; then
            printf '\n' >> "$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
        printf '%s\n' "$NFT_INCLUDE_LINE" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    atomic_copy "$tmp" "$NFT_CONF"
    local rc=$?
    rm -f -- "$tmp"
    return "$rc"
}

snapshot_firewall() {
    local dir="$1"
    snapshot_file "$NFT_CONF" "$dir/nftables.conf" || return 1
    snapshot_file "$NFT_MANAGED_CONF" "$dir/managed.conf" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    nft_cmd list tables > "$dir/tables" || return 1
    if awk -v f="$MGR_FAMILY" -v t="$MGR_TABLE" '
        $1 == "table" && $2 == f && $3 == t { found=1 }
        END { exit !found }
    ' "$dir/tables"; then
        nft_cmd list table "$MGR_FAMILY" "$MGR_TABLE" > "$dir/managed.nft" || return 1
    else
        : > "$dir/managed.nft.missing" || return 1
    fi
}

restore_firewall_files() {
    local dir="$1" failed=0
    restore_file "$dir/nftables.conf" "$NFT_CONF" || failed=1
    restore_file "$dir/managed.conf" "$NFT_MANAGED_CONF" || failed=1
    restore_file "$dir/tcp.list" "$TCP_FILE" || failed=1
    restore_file "$dir/udp.list" "$UDP_FILE" || failed=1
    return "$failed"
}

restore_firewall_rules() {
    local dir="$1" restore="$1/restore.nft"
    printf 'add table %s %s\ndelete table %s %s\n' \
        "$MGR_FAMILY" "$MGR_TABLE" "$MGR_FAMILY" "$MGR_TABLE" > "$restore" || return 1
    if [ -f "$dir/managed.nft" ]; then
        cat "$dir/managed.nft" >> "$restore" || return 1
    elif [ ! -f "$dir/managed.nft.missing" ]; then
        return 1
    fi
    nft_cmd -f "$restore"
}

apply_config_file() (
    local config="$1" action_name="$2" dir transaction
    local runtime_dirty=0 committed=0
    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/apply.XXXXXX")" || return 1
    snapshot_firewall "$dir" || return 1
    transaction="$dir/apply.nft"
    write_nft_apply_transaction "$transaction" "$config" || return 1

    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_apply() {
        local rc="$?" failed=0
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_firewall_files "$dir" || failed=1
            if [ "$runtime_dirty" = 1 ]; then
                restore_firewall_rules "$dir" || failed=1
            fi
            if [ "$failed" = 1 ]; then
                echo "[ERROR] Firewall rollback incomplete. Backups: $dir" >&2
            fi
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_apply EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    echo "[+] Checking nftables transaction..."
    nft_cmd -c -f "$transaction" || return 1
    mkdir -p -- "$(dirname "$NFT_MANAGED_CONF")" || return 1
    atomic_copy "$config" "$NFT_MANAGED_CONF" || return 1
    ensure_managed_include || return 1
    write_nft_apply_transaction "$transaction" "$NFT_MANAGED_CONF" || return 1
    echo "[+] Applying nftables transaction..."
    runtime_dirty=1
    if ! nft_cmd -f "$transaction"; then
        # nft batches are atomic: a rejected transaction leaves the old rules intact.
        runtime_dirty=0
        echo "[ERROR] nft apply failed; restoring saved configuration." >&2
        return 1
    fi
    if has_cmd systemctl && ! systemctl is-enabled --quiet nftables 2>/dev/null; then
        systemctl enable nftables || echo "[WARN] Rules are active, but enabling nftables at boot failed." >&2
    fi
    if [ "$AUTO_CONFIGURE_LOG_LIMIT" = 1 ]; then
        configure_journal_limit || echo "[WARN] Could not configure log limits." >&2
    fi
    committed=1
    echo "[OK] $action_name completed. Backups: $dir"
)

apply_changes() {
    local tmp rc=0
    tmp="$(mktemp)" || return 1
    if write_unified_nft_conf "$tmp"; then
        apply_config_file "$tmp" Apply || rc=$?
    else
        rc=1
    fi
    rm -f -- "$tmp"
    return "$rc"
}

# Take this snapshot BEFORE editing the list, including when Apply is requested
# from Add/Remove. A separate --apply keeps the lists saved before that invocation.
save_ports_with_prompt() (
    local file="$1" ports="$2" label="$3" dir yn committed=0
    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/ports.XXXXXX")" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_port_edit() {
        local rc="$?"
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_file "$dir/tcp.list" "$TCP_FILE" || echo "[ERROR] TCP list restore failed: $dir" >&2
            restore_file "$dir/udp.list" "$UDP_FILE" || echo "[ERROR] UDP list restore failed: $dir" >&2
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_port_edit EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    write_csv_file "$file" "$ports" || return 1
    echo "[OK] Saved $label ports:"
    cat "$file"
    read -r -p "Apply now? This updates $NFT_MANAGED_CONF, preserves $NFT_CONF, and reloads only the managed nft table. (y/n): " yn || return 1
    case "$yn" in
        y|Y) apply_changes || return 1 ;;
        *) echo "[INFO] saved but not applied yet" ;;
    esac
    committed=1
)

detect_baseline_ssh_port() {
    local _client_ip _client_port _server_ip session_port extra listeners ports sshd_bin source
    read -r _client_ip _client_port _server_ip session_port extra <<< "${SSH_CONNECTION:-}" || true
    if [ -z "$session_port" ]; then
        read -r _client_ip _client_port session_port extra <<< "${SSH_CLIENT:-}" || true
    fi
    case "$session_port" in
        22|26) ;;
        *) session_port="" ;;
    esac
    [ -z "$extra" ] || session_port=""

    ports=""
    # A session opened on 22 can survive migration to 26. Prefer current sshd
    # listeners so the next connection remains possible after initialization.
    if has_cmd ss && listeners="$(ss -H -ltnp 2>/dev/null)"; then
        ports="$(awk '/"sshd"|"sshd-session"/ {
            n=split($4,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]
        }' <<< "$listeners" | sort -nu)"
    fi
    source="SSH listeners"
    if [ -z "$ports" ] && [ -n "$session_port" ]; then
        printf '%s\n' "$session_port"
        return 0
    fi
    if [ -z "$ports" ] && sshd_bin="$(find_sshd_binary)"; then
        ports="$(effective_sshd_ports "$sshd_bin" 2>/dev/null)" || ports=""
        source="effective SSH configuration"
    fi
    ports="$(awk '$1 == 22 || $1 == 26 { print $1 }' <<< "$ports" | sort -nu)"
    case "$ports" in
        22|26)
            echo "[INFO] Baseline SSH port: $ports ($source)." >&2
            printf '%s\n' "$ports"
            ;;
        $'22\n26')
            if [ -n "$session_port" ]; then
                printf '%s\n' "$session_port"
            else
                echo "[ERROR] SSH uses both 22 and 26 and the current SSH connection is unknown; baseline unchanged." >&2
                return 1
            fi
            ;;
        *)
            echo "[ERROR] Cannot identify SSH port 22 or 26 from listeners, connection, or configuration; baseline unchanged." >&2
            return 1
            ;;
    esac
}

reset_port_files_to_safe_defaults() {
    local ssh_port="${1:-}"
    if [ -z "$ssh_port" ]; then
        ssh_port="$(detect_baseline_ssh_port)" || return 1
    fi
    write_csv_file "$TCP_FILE" "$ssh_port,80,443" || return 1
    write_csv_file "$UDP_FILE" ""
}

detect_ssh_service() {
    local unit
    for unit in ssh.service sshd.service; do
        if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" = loaded ] &&
            systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit"
            return 0
        fi
    done
    return 1
}

find_sshd_binary() {
    if has_cmd sshd; then
        command -v sshd
    elif [ -x /usr/sbin/sshd ]; then
        printf '%s\n' /usr/sbin/sshd
    else
        return 1
    fi
}

effective_sshd_ports() {
    local config
    config="$("$1" -T -f "$SSHD_CONFIG")" || return 1
    awk '$1 == "port" { print $2 }' <<< "$config"
}

sshd_config_migrated() {
    local ports
    ports="$(effective_sshd_ports "$1")" || return 1
    grep -qx "$SSH_NEW_PORT" <<< "$ports" && ! grep -qx "$SSH_OLD_PORT" <<< "$ports"
}

ssh_listeners_migrated() {
    local listeners
    listeners="$(ss -H -ltnp)" || return 1
    # ss -p identifies the owner; another application's port 26 is not SSH.
    awk -v old="$SSH_OLD_PORT" -v new="$SSH_NEW_PORT" '
        { n=split($4,a,":"); port=a[n] }
        port == old { old_seen=1 }
        port == new && /"sshd"/ { new_seen=1 }
        END { exit !(new_seen && !old_seen) }
    ' <<< "$listeners"
}

wait_for_ssh_listeners() {
    local attempt
    for attempt in 1 2 3 4 5; do
        ssh_listeners_migrated && return 0
        [ "$attempt" -lt 5 ] || break
        sleep 1
    done
    echo "[ERROR] SSH must listen on 26, with no remaining listener on 22." >&2
    return 1
}

reload_ssh_service() {
    # Never fall back to stopping sshd during a remote migration.
    systemctl reload "$1" && systemctl is-active --quiet "$1"
}

migration_preflight() {
    local sshd_bin="$1" unit="$2" socket args pid enabled
    need_root
    ensure_systemctl || return 1
    if [ ! -f /etc/debian_version ] || ! has_cmd apt-get || ! has_cmd ss; then
        echo "[ERROR] Migration requires Debian, apt-get and ss (iproute2)." >&2
        return 1
    fi
    [ -n "$NFT_BIN" ] && [ -x "$NFT_BIN" ] && [ -f "$SSHD_CONFIG" ] || return 1
    for socket in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$socket" 2>/dev/null ||
            systemctl is-enabled --quiet "$socket" 2>/dev/null; then
            echo "[ERROR] $socket is active/enabled; socket-activated SSH is unsupported." >&2
            return 1
        fi
    done
    args="$(systemctl show -p ExecStart --value "$unit")" || return 1
    pid="$(systemctl show -p MainPID --value "$unit")" || return 1
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [ -r "/proc/$pid/cmdline" ]; then
        args+=" $(tr '\0' ' ' < "/proc/$pid/cmdline")"
    fi
    if [[ "$args" != *sshd* ]] || grep -Eq '(^|[[:space:]])-(f|p|o)' <<< "$args"; then
        echo "[ERROR] SSH uses an unsupported launcher or command-line configuration override." >&2
        return 1
    fi
    enabled="$(systemctl is-enabled fail2ban.service 2>/dev/null || true)"
    case "$enabled" in
        masked*) echo "[ERROR] Fail2ban is masked; migration cancelled." >&2; return 1 ;;
    esac
    "$sshd_bin" -t -f "$SSHD_CONFIG" || return 1
    effective_sshd_ports "$sshd_bin" >/dev/null || return 1
    nft_cmd list tables >/dev/null || return 1
    [[ "$FAIL2BAN_MAXRETRY" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$FAIL2BAN_BANTIME" =~ ^[0-9]+[smhdw]?$ ]] || return 1
    [[ "$FAIL2BAN_FINDTIME" =~ ^[0-9]+[smhdw]?$ ]] || return 1
}

write_sshd_migration_config() {
    local dir="$1" tmp="$1/sshd_config.new" pattern included=0
    mkdir -p "$SSHD_DROPIN_DIR" || return 1
    # Preserve unrelated directives verbatim, including other Port directives.
    awk -v old="$SSH_OLD_PORT" '
        {
            directive=$0
            sub(/#.*/, "", directive)
            gsub(/=/, " ", directive)
            sub(/^[[:space:]]+/, "", directive)
            split(directive, fields, /[[:space:]]+/)
            if (tolower(fields[1]) == "port" && fields[2] ~ /^[0-9]+$/ && fields[2]+0 == old)
                print "# nftfw disabled: " $0
            else
                print
        }
    ' "$SSHD_CONFIG" > "$tmp" || return 1
    cat > "$dir/sshd_dropin.new" <<EOF_SSHD
# Managed by firewall_nft_manager.sh.
Port $SSH_NEW_PORT
EOF_SSHD
    atomic_copy "$dir/sshd_dropin.new" "$SSHD_DROPIN_FILE" || return 1
    atomic_copy "$tmp" "$SSHD_CONFIG" || return 1
    # Recognize global Includes, including Debian's usual *.conf wildcard.
    # Place a missing Include at the beginning, never inside a Match block.
    while IFS= read -r pattern; do
        case "$pattern" in
            /*) ;;
            *) pattern="/etc/ssh/$pattern" ;;
        esac
        # Include operands intentionally use shell-style wildcard matching.
        # shellcheck disable=SC2254
        case "$SSHD_DROPIN_FILE" in
            $pattern) included=1 ;;
        esac
    done < <(awk '
        { sub(/#.*/, ""); gsub(/=/, " ") }
        tolower($1) == "match" { exit }
        tolower($1) == "include" {
            for (i=2; i<=NF; i++) {
                gsub(/^[\042\047]|[\042\047]$/, "", $i)
                print $i
            }
        }
    ' "$SSHD_CONFIG")
    if [ "$included" = 0 ]; then
        { printf '# Managed SSH port include\nInclude "%s"\n' "$SSHD_DROPIN_FILE"; cat "$SSHD_CONFIG"; } > "$tmp" || return 1
        atomic_copy "$tmp" "$SSHD_CONFIG" || return 1
    fi
}

ensure_fail2ban() {
    if has_cmd fail2ban-client && has_systemd_journal; then
        return 0
    fi
    echo "[+] Installing Debian Fail2ban and its systemd journal backend..."
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd || return 1
    has_cmd fail2ban-client && has_systemd_journal
}

has_systemd_journal() {
    /usr/bin/python3 -c 'from systemd import journal' >/dev/null 2>&1
}

render_fail2ban_jail() {
    cat <<EOF_FAIL2BAN
# Managed by firewall_nft_manager.sh.
[sshd]
enabled = true
port = $SSH_NEW_PORT
filter = sshd
backend = systemd
banaction = nftables-multiport
# Explicit action also overrides any inherited iptables action.
action = nftables-multiport[name=sshd, port="$SSH_NEW_PORT", protocol=tcp, nftables="$NFT_BIN"]
bantime = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY
EOF_FAIL2BAN
}

fail2ban_runtime_ready() {
    local value expected property
    has_cmd fail2ban-client || return 1
    systemctl is-active --quiet fail2ban.service || return 1
    fail2ban-client status sshd >/dev/null 2>&1 || return 1
    value="$(fail2ban-client get sshd action nftables-multiport port 2>/dev/null)" || return 1
    [ "$value" = "$SSH_NEW_PORT" ] || return 1
    value="$(fail2ban-client get sshd action nftables-multiport nftables 2>/dev/null)" || return 1
    [ "$value" = "$NFT_BIN" ] || return 1
    value="$(fail2ban-client get sshd maxretry 2>/dev/null)" || return 1
    [ "$value" = "$FAIL2BAN_MAXRETRY" ] || return 1
    for property in bantime findtime; do
        case "$property" in
            bantime) expected="$FAIL2BAN_BANTIME" ;;
            findtime) expected="$FAIL2BAN_FINDTIME" ;;
        esac
        expected="$(fail2ban-client --str2sec "$expected")" || return 1
        value="$(fail2ban-client get sshd "$property" 2>/dev/null)" || return 1
        [ "$value" = "$expected" ] || return 1
    done
}

wait_for_fail2ban() {
    local attempt
    for attempt in 1 2 3 4 5; do
        fail2ban_runtime_ready && return 0
        [ "$attempt" -lt 5 ] || break
        sleep 1
    done
    echo "[ERROR] Fail2ban sshd jail did not load the expected nftables action/settings." >&2
    return 1
}

save_service_state() {
    local unit="$1" path="$2"
    systemctl is-active "$unit" > "$path.active" 2>/dev/null || true
    systemctl is-enabled "$unit" > "$path.enabled" 2>/dev/null || true
}

restore_service_enablement() {
    local unit="$1" path="$2" state
    state="$(cat "$path.enabled")"
    case "$state" in
        enabled) systemctl enable "$unit" >/dev/null ;;
        enabled-runtime) systemctl enable --runtime "$unit" >/dev/null ;;
        disabled|not-found|'' )
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                systemctl disable "$unit" >/dev/null
            fi
            ;;
    esac
}

rollback_ssh_migration() {
    local failed=0
    echo "[WARN] Rolling back SSH migration. Backups: $migration_dir"
    restore_file "$migration_dir/sshd_config" "$SSHD_CONFIG" || failed=1
    restore_file "$migration_dir/sshd_dropin" "$SSHD_DROPIN_FILE" || failed=1
    if [ "$fail2ban_touched" = 1 ]; then
        if [ -d "$migration_dir/fail2ban-config" ]; then
            cp -a -- "$migration_dir/fail2ban-config/." "$FAIL2BAN_CONFIG_DIR/" || failed=1
        fi
        restore_file "$migration_dir/fail2ban_jail" "$FAIL2BAN_JAIL_FILE" || failed=1
    fi
    # Restore access before restoring the old listener, without touching other tables.
    restore_firewall_files "$migration_dir" || failed=1
    if [ "$firewall_touched" = 1 ]; then
        restore_firewall_rules "$migration_dir" || failed=1
    fi
    if [ "$ssh_touched" = 1 ]; then
        if "$sshd_bin" -t -f "$SSHD_CONFIG"; then
            reload_ssh_service "$ssh_unit" || failed=1
        else
            failed=1
        fi
    fi
    if [ "$fail2ban_touched" = 1 ]; then
        if [ "$(cat "$migration_dir/fail2ban.active")" = active ]; then
            systemctl restart fail2ban.service || failed=1
        elif [ "$(systemctl show -p LoadState --value fail2ban.service 2>/dev/null)" = loaded ]; then
            systemctl stop fail2ban.service || failed=1
        fi
        restore_service_enablement fail2ban.service "$migration_dir/fail2ban" || failed=1
    fi
    restore_service_enablement nftables.service "$migration_dir/nftables" || failed=1
    if [ "$failed" = 0 ]; then
        echo "[WARN] Migration rolled back. Newly installed packages were retained."
    else
        echo "[ERROR] Rollback incomplete; restore manually from $migration_dir" >&2
    fi
    return "$failed"
}

migrate_ssh_to_new_port() (
    local confirm sshd_bin ssh_unit migration_dir current_tcp staged_tcp final_tcp
    local firewall_touched=0 ssh_touched=0 fail2ban_touched=0 committed=0 ssh_ready=0 jail_changed=0
    # Subshelled traps also handle a caller using 'if migrate...'; every failing
    # operation is checked explicitly rather than relying on Bash's conditional errexit.
    read -r -p "Type YES to migrate SSH 22 -> 26 and enable Fail2ban: " confirm || return 1
    if [ "$confirm" != YES ]; then
        echo "[INFO] cancelled"
        return 0
    fi
    sshd_bin="$(find_sshd_binary)" || { echo "[ERROR] sshd not found." >&2; return 1; }
    ssh_unit="$(detect_ssh_service)" || { echo "[ERROR] No active SSH service found." >&2; return 1; }
    migration_preflight "$sshd_bin" "$ssh_unit" || return 1
    current_tcp="$(csv_from_file "$TCP_FILE")" || return 1
    final_tcp="$(csv_subtract "$(csv_from_text "$current_tcp,$SSH_NEW_PORT")" "$SSH_OLD_PORT")" || return 1
    if sshd_config_migrated "$sshd_bin" && ssh_listeners_migrated; then
        ssh_ready=1
    fi
    if [ "$ssh_ready" = 1 ] && [ "$current_tcp" = "$final_tcp" ] &&
        cmp -s "$FAIL2BAN_JAIL_FILE" <(render_fail2ban_jail) &&
        fail2ban_runtime_ready && systemctl is-enabled --quiet fail2ban.service; then
        # Validate the live managed table too: saved lists alone cannot prove that
        # a previous interrupted migration actually applied its final firewall.
        if managed_rules_match; then
            echo "[OK] SSH 26 and Fail2ban are already configured; no changes needed."
            return 0
        fi
    fi

    umask 077
    migration_dir="$(mktemp -d "$BACKUP_DIR/ssh-migration.XXXXXX")" || return 1
    snapshot_firewall "$migration_dir" || return 1
    snapshot_file "$SSHD_CONFIG" "$migration_dir/sshd_config" || return 1
    snapshot_file "$SSHD_DROPIN_FILE" "$migration_dir/sshd_dropin" || return 1
    snapshot_file "$FAIL2BAN_JAIL_FILE" "$migration_dir/fail2ban_jail" || return 1
    if [ -d "$FAIL2BAN_CONFIG_DIR" ]; then
        cp -a "$FAIL2BAN_CONFIG_DIR" "$migration_dir/fail2ban-config" || return 1
    fi
    save_service_state "$ssh_unit" "$migration_dir/ssh"
    save_service_state fail2ban.service "$migration_dir/fail2ban"
    save_service_state nftables.service "$migration_dir/nftables"
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_migration() {
        local rc="$?"
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            rollback_ssh_migration || true
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_migration EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    echo "[INFO] Migration backups: $migration_dir"

    # An already migrated listener needs only missing firewall/jail repairs.
    if [ "$ssh_ready" = 0 ]; then
        staged_tcp="$(csv_from_text "$current_tcp,$SSH_OLD_PORT,$SSH_NEW_PORT")" || return 1
        firewall_touched=1
        write_csv_file "$TCP_FILE" "$staged_tcp" || return 1
        apply_changes || return 1
        ssh_touched=1
        write_sshd_migration_config "$migration_dir" || return 1
        "$sshd_bin" -t -f "$SSHD_CONFIG" || return 1
        if ! sshd_config_migrated "$sshd_bin"; then
            echo "[ERROR] Effective SSH configuration still includes port 22 or lacks port 26." >&2
            return 1
        fi
        reload_ssh_service "$ssh_unit" || return 1
        wait_for_ssh_listeners || return 1
        sshd_config_migrated "$sshd_bin" || return 1
    elif ! csv_contains_port "$current_tcp" "$SSH_NEW_PORT" || ! managed_rules_match; then
        firewall_touched=1
        write_csv_file "$TCP_FILE" "$(csv_from_text "$current_tcp,$SSH_NEW_PORT")" || return 1
        apply_changes || return 1
    fi

    fail2ban_touched=1
    ensure_fail2ban || return 1
    mkdir -p "$(dirname "$FAIL2BAN_JAIL_FILE")" || return 1
    render_fail2ban_jail > "$migration_dir/fail2ban_jail.new" || return 1
    if ! cmp -s "$FAIL2BAN_JAIL_FILE" "$migration_dir/fail2ban_jail.new"; then
        atomic_copy "$migration_dir/fail2ban_jail.new" "$FAIL2BAN_JAIL_FILE" || return 1
        jail_changed=1
    fi
    fail2ban-client -t || return 1
    if systemctl is-active --quiet fail2ban.service; then
        if [ "$jail_changed" = 1 ] || ! fail2ban_runtime_ready; then
            # Restart the jail (not other jails) to replace an old backend/action.
            fail2ban-client reload --restart sshd || return 1
        fi
    else
        systemctl start fail2ban.service || return 1
    fi
    if ! systemctl is-enabled --quiet fail2ban.service; then
        systemctl enable fail2ban.service || return 1
    fi
    wait_for_fail2ban || return 1
    if [ "$(csv_from_file "$TCP_FILE")" != "$final_tcp" ] || ! managed_rules_match; then
        firewall_touched=1
        write_csv_file "$TCP_FILE" "$final_tcp" || return 1
        apply_changes || return 1
    fi
    sshd_config_migrated "$sshd_bin" && ssh_listeners_migrated && fail2ban_runtime_ready || return 1
    committed=1
    echo "[OK] SSH uses TCP 26; TCP 22 is closed. Fail2ban sshd jail is active."
)

# A saved list is not proof that the last firewall application completed.
managed_rules_match() {
    local rules live proto file
    rules="$(nft_cmd -nn list table "$MGR_FAMILY" "$MGR_TABLE" 2>/dev/null)" || return 1
    for proto in tcp udp; do
        file="$TCP_FILE"
        [ "$proto" = tcp ] || file="$UDP_FILE"
        live="$(printf '%s\n' "$rules" \
            | sed -n "/comment \"nftfw: accept managed $proto\"/s/.*$proto dport \(.*\) accept comment.*/\1/p" \
            | tr -d '{} ')"
        [ "$(csv_from_text "$live")" = "$(csv_from_file "$file")" ] || return 1
    done
    grep -Eq 'hook input priority (filter|0); policy drop;' <<< "$rules" || return 1
    grep -Fq 'comment "nftfw: log unmanaged new"' <<< "$rules" || return 1
    grep -Fq "log prefix \"$(nft_escape_string "$LOG_PREFIX_NFT")\"" <<< "$rules" || return 1
}

initialize_nft_safe() (
    local confirm dir ssh_port committed=0
    ssh_port="$(detect_baseline_ssh_port)" || return 1
    echo "[WARN] Emergency Initialize will reset the managed firewall table:"
    echo "[WARN]   Main config (preserved): $NFT_CONF"
    echo "[WARN]   Managed fragment: $NFT_MANAGED_CONF"
    echo "[WARN]   Table:  $MGR_FAMILY $MGR_TABLE"
    echo "[WARN]   TCP allowed: $ssh_port,80,443"
    echo "[WARN]   UDP allowed: none"
    echo "[WARN]   Forward: drop"
    echo "[WARN]   Output: accept"
    echo "[INFO] Foreign tables, including Docker and Fail2ban, are preserved."
    read -r -p "Type YES to initialize/recover nftables now: " confirm || return 1

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/initialize.XXXXXX")" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_initialize() {
        local rc="$?"
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_file "$dir/tcp.list" "$TCP_FILE" || echo "[ERROR] TCP list restore failed: $dir" >&2
            restore_file "$dir/udp.list" "$UDP_FILE" || echo "[ERROR] UDP list restore failed: $dir" >&2
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_initialize EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    reset_port_files_to_safe_defaults "$ssh_port" || return 1
    write_unified_nft_conf "$dir/generated.nft" || return 1
    apply_config_file "$dir/generated.nft" "Emergency initialize" || return 1
    committed=1
    echo "[OK] Safe baseline is active: TCP $ssh_port,80,443 only; UDP empty."
)

reset_saved_ports() (
    local confirm ssh_port dir committed=0
    ssh_port="$(detect_baseline_ssh_port)" || return 1
    echo "[WARN] This resets saved port lists only:"
    echo "TCP: $ssh_port,80,443"
    echo "UDP: empty"
    echo "[WARN] It does not apply/restart nftables until you choose Apply."
    read -r -p "Type YES to reset saved lists: " confirm || return 1

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/reset.XXXXXX")" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_reset() {
        local rc="$?"
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_file "$dir/tcp.list" "$TCP_FILE" || echo "[ERROR] TCP list restore failed: $dir" >&2
            restore_file "$dir/udp.list" "$UDP_FILE" || echo "[ERROR] UDP list restore failed: $dir" >&2
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_reset EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    reset_port_files_to_safe_defaults "$ssh_port" || return 1
    committed=1
    echo "[OK] saved port lists reset"
)

show_nftables_active_status() {
    local active_status enabled_status
    if has_cmd systemctl; then
        active_status="$(systemctl is-active nftables 2>/dev/null || true)"
        enabled_status="$(systemctl is-enabled nftables 2>/dev/null || true)"

        echo "nftables active: ${active_status:-unknown}"
        echo "nftables enabled: ${enabled_status:-unknown}"
    else
        echo "nftables active: unknown (systemctl not found)"
    fi

    echo "target config: $NFT_CONF"
    echo "managed fragment: $NFT_MANAGED_CONF"
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
    nft_cmd list table "$MGR_FAMILY" "$MGR_TABLE" 2>/dev/null || echo "No active target table found: $MGR_FAMILY $MGR_TABLE"
    echo ""

    echo "=== Foreign active tables ==="
    foreign_tables 2>/dev/null || true
    echo ""

    echo "=== Global dport/log/nat rules for reference only ==="
    nft_cmd list ruleset 2>/dev/null | grep -E 'dport|log prefix|counter drop|dnat|nftfw|nft-new' || echo "No active matching rules found"
    echo ""

    echo "=== Current persistent config paths ==="
    echo "main: $NFT_CONF"
    echo "managed: $NFT_MANAGED_CONF"
}

show_generated_config() {
    local tmp tcp_ports ssh_port rc=0
    if [ ! -s "$TCP_FILE" ]; then
        ssh_port="$(detect_baseline_ssh_port)" || return 1
        tcp_ports="$ssh_port,80,443"
    else
        tcp_ports="$(csv_from_file "$TCP_FILE")" || return 1
    fi
    tmp="$(mktemp)" || return 1
    if ! write_unified_nft_conf "$tmp" "$tcp_ports"; then
        rm -f "$tmp"
        return 1
    fi
    echo "=== Generated managed fragment preview ($NFT_MANAGED_CONF) ==="
    cat "$tmp" || rc=1
    rm -f "$tmp"
    return "$rc"
}

# Read one numeric JSON snapshot. Port lists cannot express address, interface,
# family, set, jump-path, or connection-state constraints; never discard them.
extract_active_accept_ports() {
    local snapshot="$1"
    python3 - "$snapshot" "$MGR_FAMILY" "$MGR_TABLE" <<'PY_IMPORT'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        entries = json.load(stream)["nftables"]
    family, table = sys.argv[2:]
    tables = [e["table"] for e in entries if "table" in e
              and (e["table"].get("family"), e["table"].get("name")) == (family, table)]
    if len(tables) != 1 or tables[0].get("flags"):
        raise ValueError("requires an active managed table without special flags")
    chains = [e["chain"] for e in entries if "chain" in e
              and e["chain"].get("family") == family and e["chain"].get("table") == table]
    inputs = [c for c in chains if c.get("hook") == "input"]
    if len(inputs) != 1 or inputs[0].get("name") != "input" or inputs[0].get("type") != "filter":
        raise ValueError("requires exactly one base input chain named input in the managed inet table")
    if any(c.get("hook") in ("prerouting", "ingress") for c in chains):
        raise ValueError("managed ingress/prerouting chains may constrain input traffic")

    def ports(value):
        if type(value) is int and 1 <= value <= 65535:
            return [str(value)]
        if isinstance(value, dict) and set(value) == {"range"}:
            bounds = value["range"]
            if (isinstance(bounds, list) and len(bounds) == 2
                    and all(type(x) is int and 1 <= x <= 65535 for x in bounds)
                    and bounds[0] <= bounds[1]):
                return [f"{bounds[0]}-{bounds[1]}"]
        if isinstance(value, dict) and set(value) == {"set"} and isinstance(value["set"], list):
            result = []
            for item in value["set"]:
                result.extend(ports(item))
            if result:
                return result
        raise ValueError("port expression is not a numeric port/range/anonymous set")

    result = {"tcp": [], "udp": []}
    blocked = False
    skipped = 0
    for entry in entries:
        rule = entry.get("rule", {})
        if (rule.get("family"), rule.get("table"), rule.get("chain")) != (family, table, "input"):
            continue
        expr = rule.get("expr", [])
        # This exact invalid-state drop is also emitted by our generated baseline.
        invalid_drop = len(expr) == 2 and expr[-1] == {"drop": None} and expr[0] in (
            {"match": {"op": "in", "left": {"ct": {"key": "state"}}, "right": 1}},
            {"match": {"op": "==", "left": {"ct": {"key": "state"}}, "right": "invalid"}},
        )
        if not invalid_drop and any(set(e) - {"match", "counter", "log", "accept", "limit"} for e in expr):
            blocked = True  # drop/reject/jump/return/mark/map/etc. may restrict a later accept.
        if not expr or expr[-1] != {"accept": None}:
            continue
        matches = [e["match"] for e in expr if set(e) == {"match"}]
        if (blocked or len(matches) != 1
                or any(len(e) != 1 or set(e) - {"match", "counter", "log", "accept"} for e in expr)
                or sum("accept" in e for e in expr) != 1):
            skipped += 1
            continue
        match = matches[0]
        proto = next((p for p in result if match.get("left") == {"payload": {"protocol": p, "field": "dport"}}), None)
        if proto is None or match.get("op") != "==":
            skipped += 1
            continue
        try:
            result[proto].extend(ports(match.get("right")))
        except ValueError:
            skipped += 1
    for proto, items in result.items():
        for item in items:
            print(proto, item)
    if skipped:
        print(f"[INFO] Skipped {skipped} input accept rule(s) with constraints or unsupported expressions.", file=sys.stderr)
except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
    print(f"[ERROR] Safe import failed: {error}", file=sys.stderr)
    sys.exit(1)
PY_IMPORT
}

import_active_accept_ports() (
    local dir current_tcp current_udp merged_tcp merged_udp active_tcp active_udp committed=0
    if ! has_cmd python3; then
        echo "[ERROR] Safe JSON import requires python3; saved lists were not changed." >&2
        return 1
    fi
    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/import.XXXXXX")" || return 1
    # -nn prevents service-name conversion. Never scrape the full textual ruleset.
    nft_cmd -j -nn list table "$MGR_FAMILY" "$MGR_TABLE" > "$dir/active.json" || return 1
    extract_active_accept_ports "$dir/active.json" > "$dir/ports" || return 1
    active_tcp="$(awk '$1 == "tcp" { print $2 }' "$dir/ports" | paste -sd, -)" || return 1
    active_udp="$(awk '$1 == "udp" { print $2 }' "$dir/ports" | paste -sd, -)" || return 1
    current_tcp="$(csv_from_file "$TCP_FILE")" || return 1
    current_udp="$(csv_from_file "$UDP_FILE")" || return 1
    merged_tcp="$(csv_from_text "$current_tcp,$active_tcp")" || return 1
    merged_udp="$(csv_from_text "$current_udp,$active_udp")" || return 1
    if [ "$merged_tcp" = "$current_tcp" ] && [ "$merged_udp" = "$current_udp" ]; then
        echo "[INFO] No additional unrestricted input ports to import."
        return 0
    fi
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    # Invoked by the EXIT trap.
    # shellcheck disable=SC2329
    finish_import() {
        local rc="$?"
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_file "$dir/tcp.list" "$TCP_FILE" || echo "[ERROR] TCP list restore failed: $dir" >&2
            restore_file "$dir/udp.list" "$UDP_FILE" || echo "[ERROR] UDP list restore failed: $dir" >&2
            [ "$rc" -ne 0 ] || rc=1
        fi
        exit "$rc"
    }
    trap finish_import EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    write_csv_file "$TCP_FILE" "$merged_tcp" || return 1
    write_csv_file "$UDP_FILE" "$merged_udp" || return 1
    committed=1
    echo "[OK] Imported unrestricted ports from $MGR_FAMILY $MGR_TABLE input. Saved only; Apply is separate."
    echo "TCP: ${merged_tcp:-empty}"
    echo "UDP: ${merged_udp:-empty}"
)

show_port_input_help() {
    local label="$1" file="$2" action="${3:-}" current
    current="$(csv_from_file "$file")" || return 1
    echo "Examples:"
    echo "  53"
    if [ "$label" = "UDP" ] && [ "$action" = "add" ]; then
        echo "  15000-18369"
        echo "  53,3667,15000-18369"
    else
        echo "  3666-3669"
        echo "  53,3666-3669"
    fi
    printf 'Current saved %s ports: %s\n' "$label" "${current:-none}"
}

add_ports() {
    local proto file label input add_csv current_csv new_csv
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

    show_port_input_help "$label" "$file" add || return 1
    read -r -p "port(s): " input

    add_csv="$(csv_from_text "$input")" || return 1

    if [ -z "$add_csv" ]; then
        echo "[ERROR] no valid ports found"
        return
    fi

    current_csv="$(csv_from_file "$file")" || return 1

    if [ -n "$current_csv" ]; then
        new_csv="$(csv_from_text "$current_csv,$add_csv")" || return 1
    else
        new_csv="$add_csv"
    fi

    save_ports_with_prompt "$file" "$new_csv" "$label"
}

remove_ports() {
    local proto file label input remove_csv current_csv new_csv confirm ssh_port
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

    show_port_input_help "$label" "$file" || return 1
    read -r -p "port(s) to remove: " input

    remove_csv="$(csv_from_text "$input")" || return 1
    current_csv="$(csv_from_file "$file")" || return 1

    if [ -z "$remove_csv" ]; then
        echo "[ERROR] no valid remove items"
        return
    fi

    if [ -z "$current_csv" ]; then
        echo "[INFO] no saved ports"
        return
    fi

    ssh_port="$(detect_baseline_ssh_port 2>/dev/null)" || ssh_port=""
    if [ "$file" = "$TCP_FILE" ] && {
        csv_contains_port "$remove_csv" "${ssh_port:-22}" ||
        { [ -z "$ssh_port" ] && csv_contains_port "$remove_csv" 26; }
    }; then
        echo "[WARN] You are removing the SSH port (${ssh_port:-22/26}) from this firewall list."
        echo "[WARN] Make sure another SSH path is already open and tested."
        read -r -p "Type YES to continue: " confirm

        if [ "$confirm" != "YES" ]; then
            echo "[INFO] cancelled"
            return
        fi
    fi

    new_csv="$(csv_subtract "$current_csv" "$remove_csv")" || return 1
    save_ports_with_prompt "$file" "$new_csv" "$label"
}

configure_nftables_boot() {
    ensure_systemctl || return 1

    echo "[+] Enabling nftables service at boot..."
    systemctl enable nftables || return 1
    echo "[OK] nftables service enabled. It will load: $NFT_CONF (including $NFT_MANAGED_CONF)"
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

The manager replaces only table $MGR_FAMILY $MGR_TABLE in one transaction.
Apply and emergency initialization preserve foreign active tables such as Docker
and Fail2ban. The main config is preserved; the managed fragment is:
  $NFT_MANAGED_CONF
The main config includes that fragment exactly once:
  $NFT_CONF
Input and forward default to drop; output to accept.
IPv4 Docker bridge forwarding rules remain enabled.

Baselines (first use, empty TCP list, reset and emergency initialization):
  TCP: detected SSH port (22 or 26),80,443; UDP: empty on explicit reset.
  Current sshd listeners take priority over an older SSH session's port.
  With both listeners, the current connection selects the SSH port.
  If detection is ambiguous or unavailable, initialization fails without guessing.

Import (menu 6):
  Only numeric, unrestricted TCP/UDP destination-port accept rules from the
  managed inet input base chain can be saved. Address/interface/state constraints,
  named sets, other families/tables/chains and unsupported rules are skipped.
  Earlier restrictive rules prevent importing later accepts. Requires python3.
  Import only saves lists. Apply replaces the entire managed table, including
  manual rules; manage constrained rules in a separate table.

Range-aware removal supports holes, e.g. 1002 from 1000-1005 -> 1000-1001,1003-1005.
Removing the detected SSH port prompts for confirmation.
Log size menu item 9 uses JOURNAL_LIMIT=${JOURNAL_LIMIT} by default; set
JOURNAL_LIMIT to a positive byte or K/M/G value to override it.
Menu 15 migrates SSH 22 -> 26 and configures Fail2ban with rollback on failure.
Backups: $BACKUP_DIR
EOF_HELP
}

menu() {
    local c
    while true; do
        echo ""
        echo "===== NFT FIREWALL MANAGER v$VERSION ($SCRIPT_NAME) ====="
        show_nftables_active_status
        echo "1) Show saved ports, active table, and foreign table reference"
        echo "2) Add port(s)"
        echo "3) Remove port(s), range-aware"
        echo "4) Apply saved ports to managed fragment (preserve main config)"
        echo "5) Show full active nft ruleset"
        echo "6) Import unrestricted managed input ports into saved lists"
        echo "7) Emergency initialize: detected SSH (22/26),80,443; preserve foreign tables"
        echo "8) Reset saved port lists only, no apply"
        echo "9) Configure log size limit only (default ${JOURNAL_LIMIT})"
        echo "10) Show log size status"
        echo "11) Enable nftables service at boot"
        echo "12) Preview generated config"
        echo "13) Help"
        echo "14) Exit"
        echo "15) Migrate SSH 22 -> 26 and enable Fail2ban"
        echo "======================================================="
        read -r -p "Select: " c || return 0

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
                nft_cmd list ruleset 2>/dev/null || echo "[INFO] No active nft ruleset found, or nft command failed."
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
            15)
                migrate_ssh_to_new_port
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
  bash $SCRIPT_PATH --version

Options:
  --apply       Build $NFT_MANAGED_CONF, update the include in $NFT_CONF, and reload only the managed table.
  --init-safe   Detect SSH 22/26, reset TCP to SSH/80/443 and UDP to empty, apply managed table.
  --show        Show saved ports and active table/reference rules.
  --preview     Print the managed fragment used by Apply without applying it.
  --help        Show detailed help.
  --version     Show manager version.

Environment shortcuts:
  AUTO_CONFIGURE_LOG_LIMIT=1    Configure journal/logrotate limits during Apply.
  JOURNAL_LIMIT=100M             Menu 9 default; accept bytes or K/M/G values.
  NFT_CONF=/etc/nftables.conf
  NFT_MANAGED_CONF=/etc/nftables.conf.nftfw
  SSHD_CONFIG=/etc/ssh/sshd_config  Override SSH daemon configuration path.
  FAIL2BAN_BANTIME=1h FAIL2BAN_FINDTIME=10m FAIL2BAN_MAXRETRY=5
                                Override migration jail defaults.
EOF_USAGE
}

main() {
    # Informational/invalid options must never install packages or initialize files.
    if [ "$#" -gt 1 ]; then
        echo "[ERROR] Expected at most one option." >&2
        return 1
    fi
    case "${1:-}" in
        --version) echo "$SCRIPT_NAME v$VERSION"; return 0 ;;
        --help|-h) show_cli_usage; echo ""; show_help; return 0 ;;
        ""|--apply|--init-safe|--show|--preview) ;;
        *) echo "[ERROR] unknown option: $1" >&2; show_cli_usage; return 1 ;;
    esac
    validate_manager_target || return 1
    case "${1:-}" in
        --preview)
            NFT_BIN="$(command -v nft || printf /usr/sbin/nft)"
            show_generated_config
            return
            ;;
        --show)
            need_root
            NFT_BIN="$(command -v nft || printf /usr/sbin/nft)"
            show_ports
            return
            ;;
    esac
    need_root
    ensure_nft || return 1
    ensure_dirs || return 1
    case "${1:-}" in
        --init-safe) initialize_nft_safe ;;
        --apply) init_files && apply_changes ;;
        "") init_files && menu ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

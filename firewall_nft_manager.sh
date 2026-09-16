#!/usr/bin/env bash

# Unified nftables firewall manager script.
# Default target: one persistent config file and one nft table:
#   /etc/nftables.conf -> table inet filter
#
# Main design:
# - Normal Apply writes /etc/nftables.conf and reloads nftables directly with nft -f.
# - Normal Apply does NOT use `flush ruleset`; it replaces only the managed table.
# - Forward chain keeps policy drop but allows Docker published DNAT and container outbound traffic.
# - Emergency Initialize still uses `flush ruleset` to recover to a clean baseline.
# - Port lists are stored in /etc/nft_ports_tcp.list and /etc/nft_ports_udp.list.
# - Emergency Initialize resets TCP to 22,80,443 and UDP to empty.

set -e

VERSION="2.1.0"

SCRIPT_PATH="${0:-firewall_nft_manager.sh}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
if [ -z "$SCRIPT_NAME" ]; then
    SCRIPT_NAME="firewall_nft_manager.sh"
fi

BACKUP_DIR="${BACKUP_DIR:-/etc/nftables.backup}"
TCP_FILE="${TCP_FILE:-/etc/nft_ports_tcp.list}"
UDP_FILE="${UDP_FILE:-/etc/nft_ports_udp.list}"
NFT_CONF="${NFT_CONF:-/etc/nftables.conf}"

# This version intentionally supports only one nft family/table by default.
# Keeping these configurable is mostly for advanced users, but validation below
# restricts them to the safe unified target unless ALLOW_CUSTOM_TARGET=1.
MGR_FAMILY="${MGR_FAMILY:-inet}"
MGR_TABLE="${MGR_TABLE:-filter}"
ALLOW_CUSTOM_TARGET="${ALLOW_CUSTOM_TARGET:-0}"

LOG_PREFIX_NFT="${LOG_PREFIX_NFT:-nft-new: }"
JOURNAL_LIMIT="${JOURNAL_LIMIT:-100M}"
JOURNAL_DROPIN_DIR="${JOURNAL_DROPIN_DIR:-/etc/systemd/journald.conf.d}"
JOURNAL_DROPIN_FILE="${JOURNAL_DROPIN_FILE:-$JOURNAL_DROPIN_DIR/99-nft-log-size-limit.conf}"
LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/nft-kernel-logs}"

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

# Docker compatibility: Emergency Initialize uses `flush ruleset`.
# That can remove Docker's iptables-nft/NAT chains.
# auto = after Emergency Initialize only, restart docker.service when it is already active.
# Set to 0/off/no/false to disable, or 1/on/yes/true to force when docker exists.
RESTART_DOCKER_AFTER_NFT="${RESTART_DOCKER_AFTER_NFT:-auto}"

# Normal Apply replaces only the managed nft table and preserves foreign tables.
# Emergency Initialize uses full `flush ruleset` and may remove foreign tables.
# Set SKIP_FOREIGN_TABLE_CONFIRM=1 only if you know Emergency Initialize should proceed.
SKIP_FOREIGN_TABLE_CONFIRM="${SKIP_FOREIGN_TABLE_CONFIRM:-0}"

# Log storage limits are not changed during Apply by default.
AUTO_CONFIGURE_LOG_LIMIT="${AUTO_CONFIGURE_LOG_LIMIT:-0}"

# Safety default for generated input chain. Keep this enabled for a firewall.
INPUT_POLICY_DROP="${INPUT_POLICY_DROP:-1}"

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

docker_service_active() {
    has_cmd systemctl && systemctl is-active --quiet docker 2>/dev/null
}

docker_unit_exists() {
    has_cmd systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1
}

maybe_restart_docker_after_nft() {
    local mode
    mode="$RESTART_DOCKER_AFTER_NFT"

    case "$mode" in
        0|no|NO|false|FALSE|off|OFF)
            return 0
            ;;
        auto|AUTO|"")
            if ! docker_service_active; then
                return 0
            fi
            ;;
        1|yes|YES|true|TRUE|on|ON)
            if ! docker_unit_exists; then
                return 0
            fi
            ;;
        *)
            echo "[WARN] Unknown RESTART_DOCKER_AFTER_NFT=$mode; skipping Docker restart."
            return 0
            ;;
    esac

    echo "[INFO] Restarting docker.service to rebuild Docker NAT/DOCKER chains after nftables reload..."
    if systemctl restart docker; then
        echo "[OK] docker.service restarted."
    else
        echo "[WARN] docker.service restart failed. If Docker port publishing fails, run: systemctl restart docker"
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
            echo "[ERROR] This unified version supports only MGR_FAMILY=inet by default."
            echo "[ERROR] Current MGR_FAMILY: $MGR_FAMILY"
            echo "[ERROR] Reason: the generated config contains both IPv4 and IPv6 rules in one table."
            echo "[ERROR] Use MGR_FAMILY=inet, or set ALLOW_CUSTOM_TARGET=1 only after reviewing the generated nft config."
            if [ "$ALLOW_CUSTOM_TARGET" != "1" ]; then
                exit 1
            fi
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
    touch "$TCP_FILE" "$UDP_FILE"

    if [ ! -s "$TCP_FILE" ]; then
        printf "22\n80\n443\n" > "$TCP_FILE"
    fi
}

backup_file() {
    local src name
    src="$1"
    name="$2"

    if [ -f "$src" ]; then
        cp "$src" "$BACKUP_DIR/$name.$(date +%F-%H%M%S)" || true
    fi
}

backup_persistent_files() {
    backup_file "$NFT_CONF" "nftables.conf"
    backup_file "$TCP_FILE" "nft_ports_tcp.list"
    backup_file "$UDP_FILE" "nft_ports_udp.list"
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

csv_canonicalize() {
    local csv tmp_items tmp_sorted OLDIFS item
    csv="$1"
    tmp_items="$(mktemp)"
    tmp_sorted="$(mktemp)"

    csv="$(normalize_text "$csv")"

    if [ -z "$csv" ]; then
        rm -f "$tmp_items" "$tmp_sorted"
        echo ""
        return
    fi

    OLDIFS="$IFS"
    IFS=','

    for item in $csv; do
        IFS="$OLDIFS"

        [ -n "$item" ] || {
            IFS=','
            continue
        }

        if valid_item "$item"; then
            printf '%s %s\n' "$(item_start "$item")" "$(item_end "$item")" >> "$tmp_items"
        else
            echo "[WARN] ignored invalid port item: $item" >&2
        fi

        IFS=','
    done

    IFS="$OLDIFS"

    if [ ! -s "$tmp_items" ]; then
        rm -f "$tmp_items" "$tmp_sorted"
        echo ""
        return
    fi

    sort -n -k1,1 -k2,2 "$tmp_items" > "$tmp_sorted"

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
    ' "$tmp_sorted"

    rm -f "$tmp_items" "$tmp_sorted"
}

csv_from_file() {
    local file
    file="$1"

    if [ ! -s "$file" ]; then
        echo ""
        return
    fi

    csv_canonicalize "$(cat "$file")"
}

csv_from_text() {
    local text
    text="$1"
    csv_canonicalize "$text"
}

write_csv_file() {
    local file csv
    file="$1"
    csv="$2"

    csv="$(csv_canonicalize "$csv")" || return 1
    : > "$file" || return 1

    [ -n "$csv" ] || return 0

    printf '%s\n' "$csv" | tr ',' '\n' > "$file"
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

    csv="$(csv_canonicalize "$csv")"
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
    current_csv="$(csv_canonicalize "$1")"
    remove_csv="$(csv_canonicalize "$2")"

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

show_foreign_tables_warning() {
    local foreign
    foreign="$(foreign_tables || true)"
    if [ -n "$foreign" ]; then
        echo "[WARN] Active nftables contains tables outside $MGR_FAMILY $MGR_TABLE:"
        printf '%s\n' "$foreign"
        echo "[WARN] Emergency Initialize uses 'flush ruleset'."
        echo "[WARN] It will remove those active foreign tables, including iptables-nft tables."
        return 0
    fi
    return 1
}

confirm_if_foreign_tables_exist() {
    local confirm
    if [ "$SKIP_FOREIGN_TABLE_CONFIRM" = "1" ]; then
        return 0
    fi

    if show_foreign_tables_warning; then
        echo "[WARN] Continue only if you want one clean nftables ruleset."
        read -r -p "Type YES to continue: " confirm
        if [ "$confirm" != "YES" ]; then
            echo "[INFO] cancelled"
            return 1
        fi
    fi

    return 0
}

write_unified_nft_conf() {
    local out mode tcp_ports udp_ports tcp_set udp_set log_prefix_escaped input_policy
    out="$1"
    mode="${2:-table_only}"
    tcp_ports="$(csv_from_file "$TCP_FILE")" || return 1
    udp_ports="$(csv_from_file "$UDP_FILE")" || return 1
    tcp_set="$(nft_set_from_csv "$tcp_ports")"
    udp_set="$(nft_set_from_csv "$udp_ports")"
    log_prefix_escaped="$(nft_escape_string "$LOG_PREFIX_NFT")"

    input_policy="accept"
    if [ "$INPUT_POLICY_DROP" = "1" ]; then
        input_policy="drop"
    fi

    cat > "$out" <<EOF_NFT || return 1
#!$NFT_BIN -f

# Generated by $SCRIPT_NAME
# Config file: $NFT_CONF
# Managed table: $MGR_FAMILY $MGR_TABLE
EOF_NFT

    case "$mode" in
        full_flush)
            cat >> "$out" <<EOF_NFT || return 1
# Mode: Emergency Initialize. This intentionally flushes the full ruleset.
# It removes foreign/iptables-nft generated tables, including Docker NAT chains.

flush ruleset

EOF_NFT
            ;;
        table_only|"")
            cat >> "$out" <<EOF_NFT || return 1
# Mode: Normal Apply. This preserves foreign tables.
# This file intentionally does not contain global 'flush ruleset'.
# Add is idempotent. Delete and recreate happen in the same nft transaction.
add table $MGR_FAMILY $MGR_TABLE
delete table $MGR_FAMILY $MGR_TABLE

EOF_NFT
            ;;
        *)
            echo "[ERROR] Invalid nft config mode: $mode" >&2
            return 1
            ;;
    esac

    cat >> "$out" <<EOF_NFT || return 1
table $MGR_FAMILY $MGR_TABLE {
    chain input {
        type filter hook input priority 0; policy $input_policy;

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
        ip6 nexthdr icmpv6 accept comment "nftfw: icmpv6"

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

build_unified_config() {
    local tmp mode
    tmp="$1"
    mode="${2:-table_only}"
    write_unified_nft_conf "$tmp" "$mode"
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

snapshot_firewall() {
    local dir="$1"
    snapshot_file "$NFT_CONF" "$dir/nftables.conf" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
    nft_cmd list ruleset > "$dir/active-ruleset.nft" || return 1
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
    restore_file "$dir/tcp.list" "$TCP_FILE" || failed=1
    restore_file "$dir/udp.list" "$UDP_FILE" || failed=1
    return "$failed"
}

restore_firewall_rules() {
    local dir="$1" full="${2:-0}" restore="$1/restore.nft"
    if [ "$full" = 1 ]; then
        printf 'flush ruleset\n' > "$restore" || return 1
        cat "$dir/active-ruleset.nft" >> "$restore" || return 1
    else
        printf 'add table %s %s\ndelete table %s %s\n' \
            "$MGR_FAMILY" "$MGR_TABLE" "$MGR_FAMILY" "$MGR_TABLE" > "$restore" || return 1
        if [ -f "$dir/managed.nft" ]; then
            cat "$dir/managed.nft" >> "$restore" || return 1
        elif [ ! -f "$dir/managed.nft.missing" ]; then
            return 1
        fi
    fi
    nft_cmd -f "$restore"
}

apply_config_file() (
    local config="$1" action_name="$2" full="${3:-0}" dir
    local runtime_dirty=0 committed=0
    umask 077
    if [ "$full" = 1 ]; then
        confirm_if_foreign_tables_exist || return 1
    fi
    dir="$(mktemp -d "$BACKUP_DIR/apply.XXXXXX")" || return 1
    snapshot_firewall "$dir" || return 1

    finish_apply() {
        local rc="$?" failed=0
        trap - EXIT HUP INT TERM
        if [ "$committed" = 0 ]; then
            restore_firewall_files "$dir" || failed=1
            if [ "$runtime_dirty" = 1 ]; then
                restore_firewall_rules "$dir" "$full" || failed=1
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
    nft_cmd -c -f "$config" || return 1
    atomic_copy "$config" "$NFT_CONF" || return 1
    echo "[+] Applying nftables transaction..."
    runtime_dirty=1
    if ! nft_cmd -f "$NFT_CONF"; then
        # nft batches are atomic: a rejected transaction leaves the old rules intact.
        runtime_dirty=0
        echo "[ERROR] nft apply failed; restoring saved configuration." >&2
        return 1
    fi
    if has_cmd systemctl && ! systemctl is-enabled --quiet nftables 2>/dev/null; then
        systemctl enable nftables >/dev/null 2>&1 || true
    fi
    if [ "$AUTO_CONFIGURE_LOG_LIMIT" = 1 ]; then
        configure_journal_limit || echo "[WARN] Could not configure log limits." >&2
    fi
    if [ "$full" = 1 ]; then
        maybe_restart_docker_after_nft
    fi
    committed=1
    echo "[OK] $action_name completed. Backups: $dir"
)

apply_changes() {
    local tmp rc=0
    tmp="$(mktemp)" || return 1
    if build_unified_config "$tmp" table_only; then
        apply_config_file "$tmp" Apply 0 || rc=$?
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
    read -r -p "Apply now? This rewrites $NFT_CONF and reloads only the managed nft table. (y/n): " yn || return 1
    case "$yn" in
        y|Y) apply_changes || return 1 ;;
        *) echo "[INFO] saved but not applied yet" ;;
    esac
    committed=1
)

reset_port_files_to_safe_defaults() {
    printf "22\n80\n443\n" > "$TCP_FILE" || return 1
    : > "$UDP_FILE"
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
    [ -f /etc/debian_version ] && has_cmd apt-get && has_cmd ss || {
        echo "[ERROR] Migration requires Debian, apt-get and ss (iproute2)." >&2
        return 1
    }
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
    local rules live expected proto file
    rules="$(nft_cmd -nn list table "$MGR_FAMILY" "$MGR_TABLE" 2>/dev/null)" || return 1
    for proto in tcp udp; do
        file="$TCP_FILE"
        [ "$proto" = tcp ] || file="$UDP_FILE"
        live="$(printf '%s\n' "$rules" \
            | sed -n "/comment \"nftfw: accept managed $proto\"/s/.*$proto dport \(.*\) accept comment.*/\1/p" \
            | tr -d '{} ')"
        [ "$(csv_from_text "$live")" = "$(csv_from_file "$file")" ] || return 1
    done
    expected="drop"
    [ "$INPUT_POLICY_DROP" = 1 ] || expected="accept"
    grep -Eq "hook input priority (filter|0); policy $expected;" <<< "$rules" || return 1
    grep -Fq 'comment "nftfw: log unmanaged new"' <<< "$rules" || return 1
    grep -Fq "log prefix \"$(nft_escape_string "$LOG_PREFIX_NFT")\"" <<< "$rules" || return 1
}

initialize_nft_safe() (
    local confirm dir committed=0
    echo "[WARN] Emergency Initialize will reset the firewall to a clean single-table config:"
    echo "[WARN]   Config: $NFT_CONF"
    echo "[WARN]   Table:  $MGR_FAMILY $MGR_TABLE"
    echo "[WARN]   TCP allowed: 22,80,443"
    echo "[WARN]   UDP allowed: none"
    echo "[WARN]   Forward: drop"
    echo "[WARN]   Output: accept"
    echo "[WARN] It uses 'flush ruleset' and removes active foreign tables."
    read -r -p "Type YES to initialize/recover nftables now: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    umask 077
    dir="$(mktemp -d "$BACKUP_DIR/initialize.XXXXXX")" || return 1
    snapshot_file "$TCP_FILE" "$dir/tcp.list" || return 1
    snapshot_file "$UDP_FILE" "$dir/udp.list" || return 1
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
    reset_port_files_to_safe_defaults || return 1
    build_unified_config "$dir/generated.nft" full_flush || return 1
    apply_config_file "$dir/generated.nft" "Emergency initialize" 1 || return 1
    committed=1
    echo "[OK] Safe baseline is active: TCP 22,80,443 only; UDP empty."
)

reset_saved_ports() {
    local confirm
    echo "[WARN] This resets saved port lists only:"
    echo "TCP: 22,80,443"
    echo "UDP: empty"
    echo "[WARN] It does not apply/restart nftables until you choose Apply."
    read -r -p "Type YES to reset saved lists: " confirm

    if [ "$confirm" != "YES" ]; then
        echo "[INFO] cancelled"
        return
    fi

    backup_persistent_files
    reset_port_files_to_safe_defaults

    echo "[OK] saved port lists reset"
}

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

    echo "=== Current persistent config path ==="
    echo "$NFT_CONF"
}

show_generated_config() {
    local tmp
    tmp="$(mktemp)"
    build_unified_config "$tmp" "table_only"
    echo "=== Generated normal Apply config preview ==="
    cat "$tmp"
    rm -f "$tmp"
}

extract_active_accept_ports() {
    local proto
    proto="$1"

    nft_cmd list ruleset 2>/dev/null \
        | grep -E "[[:space:]]$proto dport .* accept" \
        | sed -E "s/.*$proto dport[[:space:]]+//" \
        | sed -E 's/[[:space:]]+(counter|accept|log|comment|ct|meta|ip|ip6|iif|oif).*$//' \
        | tr -d '{} ' \
        | tr ',' '\n' \
        | sed '/^$/d' \
        | while read -r item; do
            if valid_item "$item"; then
                echo "$item"
            fi
        done \
        | awk '!seen[$0]++'
}

import_active_accept_ports() {
    local active_tcp active_udp changed current_tcp current_udp merged_tcp merged_udp
    active_tcp="$(extract_active_accept_ports tcp | paste -sd, -)"
    active_udp="$(extract_active_accept_ports udp | paste -sd, -)"

    changed=0

    if [ -n "$active_tcp" ]; then
        current_tcp="$(csv_from_file "$TCP_FILE")"
        merged_tcp="$(csv_from_text "$current_tcp,$active_tcp")"
        write_csv_file "$TCP_FILE" "$merged_tcp"
        changed=1
    fi

    if [ -n "$active_udp" ]; then
        current_udp="$(csv_from_file "$UDP_FILE")"
        merged_udp="$(csv_from_text "$current_udp,$active_udp")"
        write_csv_file "$UDP_FILE" "$merged_udp"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        echo "[OK] Imported simple active accept dport rules into saved lists."
    else
        echo "[INFO] No simple active accept dport rules found to import."
    fi

    echo ""
    echo "=== TCP saved list ==="
    cat "$TCP_FILE" 2>/dev/null || true
    echo ""
    echo "=== UDP saved list ==="
    cat "$UDP_FILE" 2>/dev/null || true
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

    save_ports_with_prompt "$file" "$new_csv" "$label"
}

remove_ports() {
    local proto file label input remove_csv current_csv new_csv confirm
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

    if [ "$file" = "$TCP_FILE" ] && csv_contains_port "$remove_csv" 22; then
        echo "[WARN] You are removing or partially removing TCP 22 from this firewall list."
        echo "[WARN] Make sure another SSH path is already open and tested."
        read -r -p "Type YES to continue: " confirm

        if [ "$confirm" != "YES" ]; then
            echo "[INFO] cancelled"
            return
        fi
    fi

    new_csv="$(csv_subtract "$current_csv" "$remove_csv")"
    save_ports_with_prompt "$file" "$new_csv" "$label"
}

configure_nftables_boot() {
    ensure_systemctl || return 1

    echo "[+] Enabling nftables service at boot..."
    systemctl enable nftables
    echo "[OK] nftables service enabled. It will load: $NFT_CONF"
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

Main behavior in this version:
  1. Manages one persistent nftables config file:
       $NFT_CONF
  2. Manages one nft table:
       $MGR_FAMILY $MGR_TABLE
  3. Normal Apply does NOT use global flush ruleset.
     It replaces only this script's managed table in a single nft transaction.
     Foreign tables created by Docker, iptables-nft, sing-box NAT, DNAT, etc. are preserved.
  4. Emergency Initialize still uses:
       flush ruleset
     to recover to one clean baseline ruleset.
  5. Input chain default is drop, with explicit allow rules for saved TCP/UDP ports.
  6. Forward is drop by default, with Docker bridge forwarding compatibility. Output is accept.
  7. Emergency Initialize resets to TCP 22,80,443 and empty UDP.
  8. Menu 15 migrates SSH from TCP 22 to 26 and enables Fail2ban transactionally.

Range-aware removal:
  Removing 1002 from 1000-1005 produces 1000-1001,1003-1005.
  Removing 1002-1003 from 1000-1005 produces 1000-1001,1004-1005.
  Removing a range that includes TCP 22 triggers an SSH warning.

Safe baseline:
  Menu 7 writes the equivalent of:
    TCP: 22,80,443
    UDP: empty
    table inet filter with input drop, forward drop, output accept

Important caution:
  Normal Apply preserves foreign nftables tables, but it still replaces the whole
  managed table: $MGR_FAMILY $MGR_TABLE. Avoid putting unrelated manual rules in
  that same table unless you want this script to own them. Backups are saved under:
    $BACKUP_DIR

  Docker compatibility in this build:
  RESTART_DOCKER_AFTER_NFT=$RESTART_DOCKER_AFTER_NFT
  Normal Apply should not disturb Docker NAT chains. Default auto means: after
  Emergency Initialize only, restart docker.service when Docker is already active,
  so Docker can recreate its DOCKER/NAT chains after a full flush.
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
        echo "4) Apply saved ports to unified /etc/nftables.conf"
        echo "5) Show full active nft ruleset"
        echo "6) Import current active accept dport rules into saved lists"
        echo "7) Emergency initialize/recover NFT to TCP 22,80,443 only"
        echo "8) Reset saved port lists only, no apply"
        echo "9) Configure log size limit only"
        echo "10) Show log size status"
        echo "11) Enable nftables service at boot"
        echo "12) Preview generated config"
        echo "13) Help"
        echo "14) Exit"
        echo "15) Migrate SSH 22 -> 26 and enable Fail2ban"
        echo "======================================================="
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
  --apply       Build $NFT_CONF from saved port lists and reload only the managed table.
  --init-safe   Emergency reset to TCP 22,80,443 and empty UDP, then restart/apply nftables.
  --show        Show saved ports and active table/reference rules.
  --preview     Print the normal Apply config without applying it.
  --help        Show detailed help.
  --version     Show manager version.

Environment shortcuts:
  SKIP_FOREIGN_TABLE_CONFIRM=1  Do not ask when foreign active nft tables exist.
  AUTO_CONFIGURE_LOG_LIMIT=1    Configure journal/logrotate limits during Apply.
  SSHD_CONFIG=/etc/ssh/sshd_config  Override SSH daemon configuration path.
  FAIL2BAN_BANTIME=1h FAIL2BAN_FINDTIME=10m FAIL2BAN_MAXRETRY=5
                                Override migration jail defaults.
EOF_USAGE
}

main() {
    if [ "${1:-}" = "--version" ]; then
        echo "$SCRIPT_NAME v$VERSION"
        return 0
    fi
    need_root
    ensure_nft
    validate_manager_target
    ensure_dirs
    init_files

    case "${1:-}" in
        "")
            menu
            ;;
        --apply)
            apply_changes
            ;;
        --init-safe|--initialize|--rescue)
            initialize_nft_safe
            ;;
        --show)
            show_ports
            ;;
        --preview)
            show_generated_config
            ;;
        --help|-h)
            show_cli_usage
            echo ""
            show_help
            ;;
        *)
            echo "[ERROR] unknown option: $1"
            show_cli_usage
            exit 1
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

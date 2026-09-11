#!/bin/sh
# Linux / POSIX sh. Uses existing system utilities; no Python or downloaded code.
# verify_tree deliberately uses a subshell so its TREE cannot replace the original.
# shellcheck disable=SC2030,SC2031
set -u
umask 077
LC_ALL=C
PATH=${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin
export LC_ALL PATH

WORK=
BACKUP=
LOCK=
COMMITTED=0

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 2; }
bounded() {
    if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; else "$@"; fi
}
safe_path() {
    case $1 in ''|*[!A-Za-z0-9_./:+-]*) return 1 ;; esac
}
file_stat() { stat -c '%d:%i:%f:%u:%g:%s:%y:%z:%h' -- "$1"; }

cleanup() {
    cleanup_status=$1
    trap - 0
    trap '' HUP INT TERM
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        if [ "$COMMITTED" -eq 0 ] && [ -s "$WORK/applied" ]; then
            say '修复未完成，正在尝试恢复本次修改……' >&2
            while IFS='|' read -r undo_id undo_path; do
                # An intent is recorded before rename, also covering signal interruptions.
                if [ ! -L "$undo_path" ] && cmp -s -- "$undo_path" "$BACKUP/$undo_id.original"; then
                    continue
                fi
                if [ -L "$undo_path" ] || ! cmp -s -- "$undo_path" "$WORK/planned/$undo_id"; then
                    say "需手动恢复：$undo_path 已再次变化；保留外部修改。备份：$BACKUP" >&2
                    cleanup_status=2
                    continue
                fi
                undo_temp=$(mktemp "${undo_path%/*}/.dd-network-restore.XXXXXX") || {
                    say "无法创建恢复文件：$undo_path；备份：$BACKUP" >&2
                    cleanup_status=2
                    continue
                }
                if cp -a -- "$BACKUP/$undo_id.original" "$undo_temp" && mv -fT -- "$undo_temp" "$undo_path"; then
                    say "已恢复：$undo_path" >&2
                else
                    say "恢复失败：$undo_path；请使用备份 $BACKUP" >&2
                    cleanup_status=2
                fi
                rm -f -- "$undo_temp"
            done < "$WORK/applied"
        fi
        if [ -f "$WORK/staged" ]; then
            while IFS='|' read -r _stage_id stage_path; do
                rm -f -- "$stage_path"
            done < "$WORK/staged"
        fi
        rm -rf -- "$WORK"
    fi
    if [ -n "$LOCK" ]; then
        rm -f -- "$LOCK/pid"
        rmdir -- "$LOCK" 2>/dev/null || :
    fi
    exit "$cleanup_status"
}

usage() {
    cat <<'HELP'
用法：sh dd-network-fix.sh [--check | --fix] [--interface 网卡]

  --check           只检测（默认），不修改网络配置
  --fix             备份并注释目标网卡的 inet6 dhcp 配置段
  --interface, -i   手动指定网卡，可重复使用；默认自动识别
  --root 目录       离线检查/修复已挂载的系统，不查询当前机器网络
  --help, -h        显示帮助

适用于 Debian/Ubuntu ifupdown（/etc/network/interfaces）。
只在无需有状态 DHCPv6 时使用 --fix。修复后需自行 reboot 生效。
返回值：0=本项无须修改/修复成功；1=发现嫌疑；2=无法处理；130=中断。
HELP
}

write_parser() {
    cat > "$PARSER" <<'AWK'
# Parse whole logical lines, retaining physical lines for exact selective edits.
function fail(message) {
    print "配置 " label ":" start ": " message > "/dev/stderr"
    bad=1
    exit 2
}
function header(word) {
    return word == "iface" || word == "auto" || word ~ /^allow-/ ||
           word == "mapping" || word == "rename" || word == "source" ||
           word ~ /^source-dir/ || word == "no-auto-down" || word == "no-scripts"
}
function safe_name(name) { return name != "" && name !~ /[^A-Za-z0-9_.:-]/ }
function safe_source(name,   k,c) {
    if (name == "" || index(name, "[[")) return 0
    for (k=1; k<=length(name); k++) {
        c=substr(name,k,1)
        if (index("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:+-*?[]!",c)==0) return 0
    }
    return 1
}
function process(text, first, last,   a,n,k,word) {
    sub(/^[ \t\r]+/, "", text)
    sub(/[ \t\r]+$/, "", text)
    if (text == "" || text ~ /^#/) return
    n=split(text,a,/[ \t]+/)
    word=a[1]
    if (header(word)) {
        selected=0
        current=0
        mapping=(word=="mapping")
        if (word=="iface") {
            if (n!=4 || !safe_name(a[2])) fail("仅支持 iface 网卡 地址族 方法；不自动处理继承/行尾注释")
            nic=a[2]; family=a[3]; method=a[4]; current=1
            selected=(family=="inet6" && method=="dhcp" && index(targets," " nic " "))
            if (mode=="scan") print "I|" nic "|" family "|" method "|" first
        } else if (word=="source" || word ~ /^source-dir/) {
            if (n!=2 || !safe_source(a[2])) fail("source 仅支持单个静态路径/通配符；多个路径请拆成多条 source")
            if (mode=="scan") print "S|" word "|" a[2] "|" first
        } else if (word=="mapping" || word=="rename" || ((word=="auto" || word ~ /^allow-/) && index(text,"="))) {
            if (mode=="scan") print "X|" word "|" first
        }
    } else {
        if (!current && !mapping) fail("孤立或不支持的指令 " word)
        if (current && family=="inet6" && method=="dhcp" &&
            word !~ /^(accept_ra|autoconf|request_prefix|ll-attempts|ll-interval|privext)$/) {
            if (mode=="scan") print "U|" nic "|" word "|" first
            if (selected) fail("DHCPv6 段含不能自动移除的选项 " word)
        }
    }
    if (selected) for (k=first;k<=last;k++) disable[k]=1
}
{
    raw[NR]=$0
    part=$0
    sub(/\r$/, "", part)
    if (!pending) {
        start=NR
        logical=""
        if (part ~ /^[ \t]*#/) next
    }
    # ifupdown joins a backslash continuation without inserting a space.
    if (part ~ /\\$/) {
        logical=logical substr(part,1,length(part)-1)
        pending=1
        next
    }
    logical=logical part
    pending=0
    process(logical,start,NR)
}
END {
    if (bad) exit 2
    if (pending) { print "配置 " label ": 未结束的反斜杠续行" > "/dev/stderr"; exit 2 }
    if (mode=="edit") for (i=1;i<=NR;i++) {
        if (disable[i] && raw[i] !~ /^[ \t]*#/ && raw[i] !~ /^[ \t\r]*$/)
            printf "# dd-network-fix disabled DHCPv6: "
        printf "%s",raw[i]
        if (i<NR || final_newline=="yes") printf "\n"
    }
}
AWK
}

init_tree() {
    mkdir -p -- "$TREE/original" "$TREE/meta" || die '无法创建检测目录'
    : > "$TREE/files"
    : > "$TREE/aliases"
    : > "$TREE/stanzas"
    : > "$TREE/unsafe"
    : > "$TREE/complex"
}

scan_file() (
    scan_alias=$1
    safe_path "$scan_alias" || die "不自动处理含空格或特殊字符的路径：$scan_alias"
    scan_real=$(readlink -f -- "$scan_alias") || die "无法解析路径：$scan_alias"
    safe_path "$scan_real" || die "不自动处理特殊路径：$scan_real"
    if [ "$OFFLINE" -eq 1 ]; then
        case $scan_real in "$SYSTEM_ROOT"/*) ;; *) die "离线配置指向系统根目录之外：$scan_alias" ;; esac
    fi
    if [ ! -f "$scan_real" ] || [ ! -r "$scan_real" ]; then die "配置不存在、不是普通文件或不可读：$scan_alias"; fi
    printf '%s|%s\n' "$scan_alias" "$scan_real" >> "$TREE/aliases"
    scan_id=$(awk -F '|' -v p="$scan_real" '$2==p {print $1}' "$TREE/files")
    scan_parent=$(readlink -f -- "${scan_alias%/*}") || die "无法解析父目录：$scan_alias"
    if [ -n "$scan_id" ]; then
        [ ! -f "$TREE/active-$scan_id" ] || die "source 循环引用：$scan_alias"
        [ "$(cat "$TREE/base-$scan_id")" = "$scan_parent" ] || die "同一文件经不同目录重复引用，相对 source 有歧义：$scan_alias"
        exit 0
    fi
    scan_count=$(wc -l < "$TREE/files")
    [ "$scan_count" -lt 128 ] || die '包含文件超过 128 个，停止自动处理'
    scan_id=$(printf '%03d' "$((scan_count + 1))")
    printf '%s|%s\n' "$scan_id" "$scan_real" >> "$TREE/files"
    printf '%s\n' "$scan_parent" > "$TREE/base-$scan_id"
    : > "$TREE/active-$scan_id"
    file_stat "$scan_real" > "$TREE/stat-$scan_id" || die "无法读取属性：$scan_real"
    cp -a -- "$scan_real" "$TREE/original/$scan_id" || die "无法读取配置：$scan_real"
    if [ "$(file_stat "$scan_real")" != "$(cat "$TREE/stat-$scan_id")" ] ||
        ! cmp -s -- "$scan_real" "$TREE/original/$scan_id"; then die "读取过程中配置变化：$scan_real"; fi
    awk -v mode=scan -v label="$scan_real" -f "$PARSER" "$TREE/original/$scan_id" > "$TREE/meta/$scan_id" || exit 2
    while IFS='|' read -r scan_type scan_a scan_b scan_c scan_d; do
        case $scan_type in
            I) printf '%s|%s|%s|%s|%s|%s\n' "$scan_a" "$scan_b" "$scan_c" "$scan_real" "$scan_d" "$scan_id" >> "$TREE/stanzas" ;;
            U) printf '%s|%s|%s|%s\n' "$scan_a" "$scan_b" "$scan_real" "$scan_c" >> "$TREE/unsafe" ;;
            X) printf '%s:%s (%s)\n' "$scan_real" "$scan_b" "$scan_a" >> "$TREE/complex" ;;
            S)
                case $scan_b in
                    /*) scan_pattern=${SYSTEM_ROOT%/}$scan_b ;;
                    *) scan_pattern=${scan_alias%/*}/$scan_b ;;
                esac
                # Only pathname expansion: never eval/source a configuration file.
                # Whitespace/shell expressions were rejected by the parser above.
                # shellcheck disable=SC2086
                set -- $scan_pattern
                for scan_match do
                    if [ ! -e "$scan_match" ] && [ ! -L "$scan_match" ]; then
                        case $scan_b in *'*'*|*'?'*|*'['*) continue ;; esac
                        die "source 路径不存在：$scan_match"
                    fi
                    case $scan_a in
                        source)
                            scan_file "$scan_match" || exit 2
                            ;;
                        source-dir*)
                            [ -d "$scan_match" ] || die "source-directory 不是目录：$scan_match"
                            for scan_entry in "$scan_match"/*; do
                                [ -e "$scan_entry" ] || [ -L "$scan_entry" ] || continue
                                scan_name=${scan_entry##*/}
                                case $scan_name in *[!A-Za-z0-9_-]*) continue ;; esac
                                [ -f "$scan_entry" ] || die "source-directory 包含非普通文件：$scan_entry"
                                scan_file "$scan_entry" || exit 2
                            done
                            ;;
                    esac
                done
                ;;
        esac
    done < "$TREE/meta/$scan_id"
    rm -f -- "$TREE/active-$scan_id"
)

read_runtime() {
    : > "$WORK/nics"
    : > "$WORK/defaults"
    : > "$WORK/managers"
    : > "$WORK/service"
    if [ "$OFFLINE" -eq 1 ]; then
        awk -F '|' '$2=="inet" && ($3=="dhcp" || $3=="static") {print $1}' "$TREE/stanzas" | sort -u > "$WORK/nics"
        say "离线模式：$SYSTEM_ROOT；仅判断配置，无法判断运行状态。"
        return
    fi
    command -v ip >/dev/null 2>&1 || die '缺少 ip 命令，无法识别实际网卡'
    ip -o link show > "$WORK/links" || die '无法查询网卡'
    awk -F ': ' '{sub(/@.*/,"",$2); print $2}' "$WORK/links" | sort -u > "$WORK/nics"
    ip -4 route show default > "$WORK/route4" || die '无法查询 IPv4 默认路由'
    awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' "$WORK/route4" | sort -u > "$WORK/defaults"
    if command -v systemctl >/dev/null 2>&1; then
        bounded systemctl show networking.service --no-pager \
            --property=LoadState,ActiveState,SubState,Result,InactiveExitTimestampMonotonic > "$WORK/service" 2>/dev/null ||
            say '提示：无法查询 networking.service 状态。'
        for manager in systemd-networkd.service NetworkManager.service; do
            manager_state=$(bounded systemctl show "$manager" --property=ActiveState --value 2>/dev/null) || manager_state=unknown
            case $manager_state in active|activating) say "$manager" >> "$WORK/managers" ;; esac
        done
    fi
    if [ -r /proc/uptime ]; then
        awk '{printf "本次开机已运行 %.1f 小时；失联并不一定是系统重启。\n",$1/3600}' /proc/uptime
    fi
    say 'networking 状态：'
    if [ -s "$WORK/service" ]; then cat "$WORK/service"; else say '未知'; fi
    say 'IPv4 默认路由：'
    if [ -s "$WORK/route4" ]; then cat "$WORK/route4"; else say '未发现'; fi
    say 'DHCP 客户端进程：'
    if command -v ps >/dev/null 2>&1; then
        ps -eo pid=,args= | awk '$2 ~ /(^|\/)(dhclient|dhcpcd|udhcpc)$/ {print}' > "$WORK/clients"
        if [ -s "$WORK/clients" ]; then cat "$WORK/clients"; else say '未观察到；可能使用其它客户端。'; fi
    fi
    if command -v journalctl >/dev/null 2>&1; then
        bounded journalctl -u networking.service -b -n 80 --no-pager -o cat > "$WORK/journal" 2>/dev/null || :
        say '本次启动的相关日志（最多 12 行）：'
        grep -Ei 'dhcp|XMT:|timed? out|fail|RTNETLINK' "$WORK/journal" | tail -n 12 || :
        say 'Request renew in +3600 等正常续租日志本身不是故障证据。'
    fi
}

select_targets() {
    if [ -n "$EXPLICIT" ]; then
        printf '%s\n' "$EXPLICIT" | awk 'NF' | sort -u > "$WORK/targets"
    else
        awk -F '|' '$1!="lo" && $2=="inet" && ($3=="dhcp" || $3=="static") {print $1}' "$TREE/stanzas" | sort -u > "$WORK/configured"
        if [ "$(wc -l < "$WORK/defaults")" -eq 1 ]; then
            cp -- "$WORK/defaults" "$WORK/targets" || die '无法选择网卡'
        else
            if [ -s "$WORK/defaults" ]; then target_pool=$WORK/defaults; else target_pool=$WORK/nics; fi
            awk 'FILENAME==ARGV[1] {a[$0]=1; next} $0 in a' "$WORK/configured" "$target_pool" > "$WORK/candidates"
            if [ "$(wc -l < "$WORK/candidates")" -eq 1 ]; then
                cp -- "$WORK/candidates" "$WORK/targets" || die '无法选择网卡'
            else
                : > "$WORK/targets"
            fi
        fi
    fi
    TARGETS=" $(tr '\n' ' ' < "$WORK/targets")"
    while IFS= read -r nic; do
        grep -Fxq -- "$nic" "$WORK/nics" || die "指定网卡不存在：$nic"
    done < "$WORK/targets"
    say "选中网卡：${TARGETS# }"
    if [ "$OFFLINE" -eq 0 ]; then
        while IFS= read -r nic; do
            ip -4 -o addr show dev "$nic" || :
            ip -6 -o addr show dev "$nic" || :
            ip -6 route show default dev "$nic" || :
        done < "$WORK/targets"
    fi
}

make_plan() {
    [ -s "$WORK/targets" ] || { say '无法唯一识别网卡；请用 --interface 指定。' >&2; return 1; }
    [ ! -s "$WORK/managers" ] || { say "其它网络管理器正在运行：$(tr '\n' ' ' < "$WORK/managers")；不自动修改。" >&2; return 1; }
    [ ! -s "$TREE/complex" ] || { say '配置含 mapping/rename/逻辑网卡映射，需人工处理：' >&2; cat "$TREE/complex" >&2; return 1; }
    if grep -Fxq 'LoadState=not-found' "$WORK/service"; then
        say '未发现 networking.service，无法确认 ifupdown 管理此网卡。' >&2
        return 1
    fi
    awk -F '|' -v targets="$TARGETS" 'index(targets," " $1 " ")' "$TREE/unsafe" > "$WORK/unsafe-selected"
    if [ -s "$WORK/unsafe-selected" ]; then
        say 'DHCPv6 段含自定义命令、DNS 或共享链路选项，需人工检查：' >&2
        cat "$WORK/unsafe-selected" >&2
        return 1
    fi
    awk -F '|' -v targets="$TARGETS" '$2=="inet6" && $3=="dhcp" && index(targets," " $1 " ") {print}' "$TREE/stanzas" > "$WORK/selected"
    while IFS='|' read -r plan_nic _plan_family _plan_method plan_path _plan_line _plan_id; do
        if ! awk -F '|' -v n="$plan_nic" '$1==n && $2=="inet" && ($3=="dhcp" || $3=="static") {found=1} END{exit !found}' "$TREE/stanzas"; then
            say "$plan_nic 没有对应的 inet dhcp/static 配置，停止修改。" >&2
            return 1
        fi
        case $plan_path in "$NETWORK_DIR"/*) ;; *) say "待修改文件位于 $NETWORK_DIR 之外：$plan_path" >&2; return 1 ;; esac
        [ "$(stat -c %h -- "$plan_path")" -eq 1 ] || { say "不自动替换硬链接：$plan_path" >&2; return 1; }
    done < "$WORK/selected"
    awk -F '|' '{print $6 "|" $4}' "$WORK/selected" | sort -u > "$WORK/changes"
}

check_native() {
    [ "$OFFLINE" -eq 0 ] || return 0
    native_phase=$1
    if ! bounded "$IFQUERY" --list --interfaces "$CONFIG" > "$WORK/query-$native_phase" 2> "$WORK/query-error" || [ -s "$WORK/query-error" ]; then
        cat "$WORK/query-error" >&2
        die "ifquery $native_phase 配置解析失败"
    fi
    sort -u "$WORK/query-$native_phase" > "$WORK/query-$native_phase.sorted" || die '无法比较 ifquery 输出'
}

verify_tree() (
    verify_phase=$1
    original_tree=$TREE
    TREE=$WORK/tree-$verify_phase
    init_tree
    scan_file "$CONFIG" || exit 2
    if ! cmp -s -- "$original_tree/files" "$TREE/files" || ! cmp -s -- "$original_tree/aliases" "$TREE/aliases"; then
        die 'source 文件列表或符号链接在检测后变化'
    fi
    while IFS='|' read -r verify_id verify_path; do
        if [ "$verify_phase" = after ] && [ -f "$WORK/planned/$verify_id" ]; then
            cmp -s -- "$verify_path" "$WORK/planned/$verify_id" || die "写入后配置被其它进程改写：$verify_path"
        else
            if ! cmp -s -- "$verify_path" "$original_tree/original/$verify_id" ||
                [ "$(file_stat "$verify_path")" != "$(cat "$original_tree/stat-$verify_id")" ]; then die "检测后配置变化：$verify_path"; fi
        fi
    done < "$original_tree/files"
    if [ "$verify_phase" = after ]; then
        awk -F '|' -v targets="$TARGETS" '$2=="inet6" && $3=="dhcp" && index(targets," " $1 " ") {found=1} END{exit found}' "$TREE/stanzas" || die '仍存在选中网卡的 DHCPv6 配置'
    fi
)

apply_fix() {
    if [ "$OFFLINE" -eq 0 ]; then
        [ "$(id -u)" -eq 0 ] || die '--fix 需要 root，请用 sudo sh dd-network-fix.sh --fix'
        IFQUERY=$(command -v ifquery) || die '缺少 ifupdown 自带的 ifquery，无法验证配置；未修改'
    fi
    BACKUP_BASE=${SYSTEM_ROOT%/}/var/backups/dd-network-fix
    if [ "$OFFLINE" -eq 1 ]; then
        backup_real=$(readlink -m -- "$BACKUP_BASE") || die '无法解析备份路径'
        case $backup_real in "$SYSTEM_ROOT"/*) ;; *) die '离线备份路径指向系统根目录之外' ;; esac
    fi
    [ ! -L "$BACKUP_BASE" ] || die "备份目录不能是符号链接：$BACKUP_BASE"
    mkdir -p -- "$BACKUP_BASE" || die "无法创建备份目录：$BACKUP_BASE"
    [ "$(stat -c %u -- "$BACKUP_BASE")" = "$(id -u)" ] || die '备份目录属主不匹配'
    backup_mode=$(stat -c %a -- "$BACKUP_BASE") || die '无法读取备份目录权限'
    [ "$((0$backup_mode & 0022))" -eq 0 ] || die '备份目录不可被组/其他用户写入'
    if mkdir -- "$BACKUP_BASE/.lock" 2>/dev/null; then
        LOCK=$BACKUP_BASE/.lock
        say "$$" > "$LOCK/pid"
    else
        die "已有修复锁：$BACKUP_BASE/.lock；确认其它修复已结束后再处理"
    fi
    check_native before
    verify_tree before || die '提交前配置检查失败'
    BACKUP=$(mktemp -d "$BACKUP_BASE/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX") || die '无法创建备份'
    : > "$BACKUP/manifest.txt" || die '无法写入备份清单'
    say '# 核对后以 root 执行；恢复完成后重启。以下命令会覆盖目标配置。' > "$BACKUP/restore-commands.txt" || die '无法写入恢复命令'
    mkdir -- "$WORK/planned" || die '无法暂存修复计划'
    while IFS='|' read -r change_id change_path; do
        cp -a -- "$TREE/original/$change_id" "$BACKUP/$change_id.original" || die "备份失败：$change_path"
        printf '%s|%s\n' "$change_id.original" "$change_path" >> "$BACKUP/manifest.txt" || die '无法写入备份清单'
        printf "cp -a -- '%s' '%s'\n" "$BACKUP/$change_id.original" "$change_path" >> "$BACKUP/restore-commands.txt" || die '无法写入恢复命令'
        final_byte=$(tail -c 1 -- "$TREE/original/$change_id" | od -An -tu1 | tr -d ' \n')
        final_newline=no
        [ "$final_byte" != 10 ] || final_newline=yes
        awk -v mode=edit -v label="$change_path" -v targets="$TARGETS" -v final_newline="$final_newline" \
            -f "$PARSER" "$TREE/original/$change_id" > "$WORK/planned/$change_id" || die "无法生成修复：$change_path"
    done < "$WORK/changes"
    (cd "$BACKUP" && sha256sum ./*.original > SHA256SUMS) || die '无法生成备份校验值'
    sync -f "$BACKUP" || die '无法将备份同步到存储设备'
    say "备份已保存：$BACKUP"
    while IFS='|' read -r change_id change_path; do
        change_temp=$(mktemp "${change_path%/*}/.dd-network-fix.XXXXXX") || die "无法创建暂存文件：$change_path"
        printf '%s|%s\n' "$change_id" "$change_temp" >> "$WORK/staged" || { rm -f -- "$change_temp"; die '无法记录暂存文件'; }
        if ! cp -a -- "$TREE/original/$change_id" "$change_temp" ||
            ! cat "$WORK/planned/$change_id" > "$change_temp"; then die "写入暂存文件失败：$change_path"; fi
        sync -f "$change_temp" || die '无法同步暂存文件'
    done < "$WORK/changes"
    # Each rename is atomic. The exit/signal trap handles partial multi-file commits.
    while IFS='|' read -r change_id change_path; do
        if [ -L "$change_path" ] || ! cmp -s -- "$change_path" "$TREE/original/$change_id" ||
            [ "$(file_stat "$change_path")" != "$(cat "$TREE/stat-$change_id")" ]; then die "提交时发现外部修改：$change_path"; fi
        change_temp=$(awk -F '|' -v id="$change_id" '$1==id {print $2}' "$WORK/staged")
        printf '%s|%s\n' "$change_id" "$change_path" >> "$WORK/applied" || die '无法记录恢复信息，停止提交'
        mv -fT -- "$change_temp" "$change_path" || die "替换失败：$change_path"
        sync -f "$change_path" || die '无法同步修改后的配置'
    done < "$WORK/changes"
    check_native after
    if [ "$OFFLINE" -eq 0 ]; then
        cmp -s -- "$WORK/query-before.sorted" "$WORK/query-after.sorted" || die 'ifquery 网卡列表发生意外变化'
    fi
    verify_tree after || die '修改后验证失败'
    COMMITTED=1
    say '配置修复成功。备份目录内有 restore-commands.txt，可用于恢复。'
    if [ "$OFFLINE" -eq 0 ]; then
        say '请执行 sudo reboot，重新 SSH 登录后再运行 sh dd-network-fix.sh --check。'
    else
        say '离线配置已修改；请启动该系统后复检。离线模式未执行 ifquery 或运行状态检查。'
    fi
    say '尚未验证真实重启及后续 IPv4 续租，请观察超过原来的故障时间窗。'
}

main() {
    MODE=check
    mode_set=
    EXPLICIT=
    SYSTEM_ROOT=/
    OFFLINE=0
    IFQUERY=
    while [ "$#" -gt 0 ]; do
        case $1 in
            --check|--fix)
                [ -z "$mode_set" ] || die '--check 和 --fix 请只选择一个'
                MODE=${1#--}; mode_set=yes; shift ;;
            --interface|-i)
                [ "$#" -ge 2 ] || die '--interface 缺少网卡名'
                case $2 in ''|*[!A-Za-z0-9_.:-]*|-*) die "无效网卡名：$2" ;; esac
                EXPLICIT="$EXPLICIT
$2"
                shift 2 ;;
            --root)
                [ "$#" -ge 2 ] || die '--root 缺少目录'
                SYSTEM_ROOT=$(readlink -f -- "$2") || die '无法解析离线根目录'
                if [ ! -d "$SYSTEM_ROOT" ] || [ "$SYSTEM_ROOT" = / ]; then die '--root 必须是已挂载/模拟系统的目录，不能是 /'; fi
                safe_path "$SYSTEM_ROOT" || die '--root 路径不能含空格或特殊字符'
                OFFLINE=1; shift 2 ;;
            --help|-h) usage; return 0 ;;
            *) die "未知参数：$1；请使用 --help" ;;
        esac
    done
    for utility in awk cat cp mv cmp mktemp readlink stat sha256sum sort grep date tail tr rm mkdir rmdir id od wc sync; do
        command -v "$utility" >/dev/null 2>&1 || die "缺少系统命令：$utility"
    done
    CONFIG=${SYSTEM_ROOT%/}/etc/network/interfaces
    NETWORK_DIR=$(readlink -f -- "${CONFIG%/*}") || die '无法解析 /etc/network'
    [ -f "$CONFIG" ] || die "未发现 $CONFIG；本脚本只支持 ifupdown，不处理 netplan/networkd/NetworkManager 配置"
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/dd-network-fix.XXXXXX") || die '无法创建临时检测目录'
    trap 'cleanup $?' 0
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    : > "$WORK/applied"
    : > "$WORK/staged"
    PARSER=$WORK/parser.awk
    write_parser || die '无法准备配置解析器'
    TREE=$WORK/tree
    init_tree
    scan_file "$CONFIG" || die '配置解析失败；未修改网络配置'
    say 'DD 后 DHCPv6 / networking 检查'
    read_runtime
    select_targets
    awk -F '|' '$2=="inet6" && $3=="dhcp" {print $4 ":" $5 "  iface " $1 " inet6 dhcp"}' "$TREE/stanzas" > "$WORK/suspects"
    if [ ! -s "$WORK/suspects" ]; then
        say '未发现启用的 inet6 dhcp 配置，本项无需修复；不代表其它网络问题已排除。'
        return 0
    fi
    say '发现以下 DHCPv6 配置嫌疑：'
    cat "$WORK/suspects"
    if grep -Fxq 'ActiveState=failed' "$WORK/service"; then
        say 'DHCPv6 配置与 networking 失败并存，符合所述故障线索，但仍需结合日志确认原因。'
    else
        say '仅凭配置不能确认故障；若 networking 持续 activating，应进一步检查 DHCPv6 日志。'
    fi
    while IFS='|' read -r warning_id warning_path; do
        if grep -Eiq 'cloud-init|automatically generated|do not edit' "$TREE/original/$warning_id"; then
            say "提示：$warning_path 含自动生成标记，请检查 cloud-init/供应商是否会覆盖修改。"
        fi
    done < "$TREE/files"
    if ! make_plan; then
        [ "$MODE" != fix ] || return 2
        return 1
    fi
    if [ ! -s "$WORK/changes" ]; then
        say '所选网卡没有 DHCPv6 段；其它网卡的嫌疑已列出，可用 --interface 指定。'
        [ "$MODE" = fix ] && [ -n "$EXPLICIT" ] && return 0
        [ "$MODE" != fix ] || return 2
        return 1
    fi
    say '计划注释目标网卡的完整 DHCPv6 段（包括其 IPv6 选项）：'
    awk -F '|' '{print "  " $4 ":" $5 "  " $1}' "$WORK/selected"
    if [ "$MODE" = check ]; then
        say '当前只检测。确认该机不依赖有状态 DHCPv6 后，加 --fix 执行修复。'
        return 1
    fi
    apply_fix
}

main "$@"

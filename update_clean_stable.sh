#!/usr/bin/env bash

set -u
set -o pipefail

# Debian / Ubuntu Update + Stable Deep Cleanup Script
#
# 支持：
#   Debian 12 / Debian 13
#   Ubuntu 20.04 / 22.04 / 24.04 / newer
#
# 用法：
#   sudo bash debian_ubuntu_update_clean_stable.sh
#   sudo bash debian_ubuntu_update_clean_stable.sh --dry-run
#   sudo bash debian_ubuntu_update_clean_stable.sh --full-upgrade
#   sudo bash debian_ubuntu_update_clean_stable.sh --no-upgrade
#   sudo bash debian_ubuntu_update_clean_stable.sh --aggressive-logs
#
# 参数：
#   --dry-run          预览模式，不实际升级、不实际删除
#   --full-upgrade     使用 apt-get dist-upgrade，允许更深度依赖调整
#   --no-upgrade       跳过系统升级，只清理垃圾
#   --no-user-cache    不清理用户目录缓存
#   --aggressive-logs  截断超过 500M 的当前日志文件
#   --help             显示帮助

DRY_RUN=0
FULL_UPGRADE=0
DO_UPGRADE=1
CLEAN_USER_CACHE=1
AGGRESSIVE_LOGS=0

JOURNAL_KEEP_DAYS=7
JOURNAL_MAX_SIZE="300M"
TMP_KEEP_DAYS=1
VAR_TMP_KEEP_DAYS=7
USER_CACHE_KEEP_DAYS=14
TRASH_KEEP_DAYS=30
OLD_LOG_KEEP_DAYS=7
BIG_LOG_SIZE="+500M"

show_help() {
    cat <<EOF
Debian / Ubuntu 系统更新 + 深度清理脚本

用法：
  sudo bash $0 [参数]

参数：
  --dry-run          预览模式，不实际升级、不实际删除
  --full-upgrade     使用 apt-get dist-upgrade，允许安装/移除依赖
  --no-upgrade       跳过系统升级，只清理垃圾
  --no-user-cache    不清理用户目录缓存
  --aggressive-logs  截断超过 500M 的当前日志文件
  --help             显示帮助

示例：
  sudo bash $0
  sudo bash $0 --dry-run
  sudo bash $0 --full-upgrade
  sudo bash $0 --no-upgrade
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        --full-upgrade)
            FULL_UPGRADE=1
            ;;
        --no-upgrade)
            DO_UPGRADE=0
            ;;
        --no-user-cache)
            CLEAN_USER_CACHE=0
            ;;
        --aggressive-logs)
            AGGRESSIVE_LOGS=1
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "未知参数：$arg"
            echo "使用 --help 查看帮助。"
            exit 1
            ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 权限运行："
    echo "sudo bash $0"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "无法识别系统：缺少 /etc/os-release"
    exit 1
fi

source /etc/os-release

OS_ID="${ID:-unknown}"
OS_NAME="${PRETTY_NAME:-unknown}"

case "$OS_ID" in
    debian|ubuntu)
        ;;
    *)
        echo "警告：当前系统不是标准 Debian / Ubuntu。"
        echo "只要系统使用 apt / dpkg，脚本通常仍可运行。"
        ;;
esac

if ! command -v apt-get >/dev/null 2>&1; then
    echo "未检测到 apt-get，当前系统不适合运行此脚本。"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

LOG_FILE="/var/log/update_clean_$(date +%Y%m%d_%H%M%S).log"

if [[ "$DRY_RUN" -eq 0 ]]; then
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""
    if [[ -n "$LOG_FILE" ]]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
fi

APT_YES_OPTS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

section() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}

print_cmd() {
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    echo
}

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_cmd "$@"
        return 0
    fi

    "$@"
}

run_critical() {
    if ! run_cmd "$@"; then
        echo
        echo "错误：关键命令执行失败："
        printf ' %q' "$@"
        echo
        echo "脚本停止。"
        exit 1
    fi
}

run_optional() {
    if ! run_cmd "$@"; then
        echo
        echo "警告：非关键命令执行失败，已跳过："
        printf ' %q' "$@"
        echo
        return 0
    fi
}

wait_for_apt_locks() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0

    if ! command -v fuser >/dev/null 2>&1; then
        return 0
    fi

    local locks=(
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    local i
    local busy

    for i in $(seq 1 60); do
        busy=0

        for lock in "${locks[@]}"; do
            if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
                busy=1
                break
            fi
        done

        if [[ "$busy" -eq 0 ]]; then
            return 0
        fi

        echo "检测到 apt/dpkg 正在被占用，等待中……"
        sleep 5
    done

    echo "等待 apt/dpkg 锁超时。请检查是否有其他 apt、dpkg、系统自动更新进程正在运行。"
    exit 1
}

apt_critical() {
    wait_for_apt_locks
    run_critical "$@"
}

apt_optional() {
    wait_for_apt_locks
    run_optional "$@"
}

guard_delete_path() {
    local path="${1:-}"

    case "$path" in
        ""|"/"|"/bin"|"/boot"|"/dev"|"/etc"|"/home"|"/lib"|"/lib64"|"/proc"|"/root"|"/run"|"/sbin"|"/sys"|"/usr"|"/var"|"/var/log")
            echo "安全保护：拒绝清理高风险路径：$path"
            return 1
            ;;
    esac

    return 0
}

safe_find_delete() {
    local path="$1"
    local days="$2"

    [[ -d "$path" ]] || return 0
    guard_delete_path "$path" || return 0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将删除 $path 下超过 $days 天的内容，预览前 100 条："
        find "$path" -xdev -mindepth 1 -ignore_readdir_race -mtime +"$days" -print 2>/dev/null | head -n 100 || true
    else
        find "$path" -xdev -mindepth 1 -ignore_readdir_race -mtime +"$days" -exec rm -rf -- {} + 2>/dev/null || true
    fi
}

delete_all_inside_dir() {
    local path="$1"

    [[ -d "$path" ]] || return 0
    guard_delete_path "$path" || return 0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将清空目录内容：$path，预览前 100 条："
        find "$path" -xdev -mindepth 1 -ignore_readdir_race -print 2>/dev/null | head -n 100 || true
    else
        find "$path" -xdev -mindepth 1 -ignore_readdir_race -exec rm -rf -- {} + 2>/dev/null || true
    fi
}

list_user_homes() {
    {
        if command -v getent >/dev/null 2>&1; then
            getent passwd | awk -F: '$3 >= 1000 && $6 ~ /^\/home\// {print $6}'
        else
            find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null
        fi

        echo "/root"
    } | sort -u
}

echo "=================================================="
echo " Debian / Ubuntu 系统更新 + 稳定清理脚本"
echo "=================================================="
echo "检测到系统：$OS_NAME"
echo "当前模式：$([[ "$DRY_RUN" -eq 1 ]] && echo "预览模式，不执行实际操作" || echo "真实执行")"

if [[ "$DO_UPGRADE" -eq 1 ]]; then
    if [[ "$FULL_UPGRADE" -eq 1 ]]; then
        echo "升级模式：full-upgrade / dist-upgrade"
    else
        echo "升级模式：普通 upgrade"
    fi
else
    echo "升级模式：跳过系统升级"
fi

if [[ "$CLEAN_USER_CACHE" -eq 1 ]]; then
    echo "用户缓存清理：开启"
else
    echo "用户缓存清理：关闭"
fi

if [[ "$AGGRESSIVE_LOGS" -eq 1 ]]; then
    echo "大日志截断：开启"
else
    echo "大日志截断：关闭"
fi

if [[ -n "${LOG_FILE:-}" && "$DRY_RUN" -eq 0 ]]; then
    echo "日志文件：$LOG_FILE"
fi

section "清理前磁盘占用"
df -h || true

section "1. 更新 APT 软件源索引"
apt_critical apt-get update

if [[ "$DO_UPGRADE" -eq 1 ]]; then
    section "2. 检查并修复未完成的软件包状态"
    apt_critical dpkg --configure -a
    apt_critical apt-get "${APT_YES_OPTS[@]}" -f install
    apt_optional apt-get check

    if [[ "$FULL_UPGRADE" -eq 1 ]]; then
        section "3. 深度更新系统：apt-get dist-upgrade"
        echo "注意：dist-upgrade 可能安装新依赖，也可能移除冲突包。"
        apt_critical apt-get "${APT_YES_OPTS[@]}" dist-upgrade
    else
        section "3. 更新系统：apt-get upgrade"
        apt_critical apt-get "${APT_YES_OPTS[@]}" upgrade
    fi

    section "4. 更新后再次检查软件包状态"
    apt_optional apt-get check
else
    section "2. 跳过系统升级"
    echo "已使用 --no-upgrade，仅执行清理。"
fi

section "5. 自动移除不再需要的软件包"
apt_optional apt-get "${APT_YES_OPTS[@]}" autoremove --purge

section "6. 清理 APT 缓存"
apt_optional apt-get clean
apt_optional apt-get autoclean -y

section "7. 清理已卸载软件残留配置包"
mapfile -t RC_PACKAGES < <(dpkg -l 2>/dev/null | awk '$1 == "rc" {print $2}' || true)

if [[ "${#RC_PACKAGES[@]}" -gt 0 ]]; then
    printf '%s\n' "${RC_PACKAGES[@]}"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将清理以上残留配置包"
    else
        run_optional dpkg --purge "${RC_PACKAGES[@]}"
    fi
else
    echo "没有发现 rc 残留配置包"
fi

section "8. 清理 systemd journal 日志"
if command -v journalctl >/dev/null 2>&1; then
    journalctl --disk-usage 2>/dev/null || true
    run_optional journalctl --vacuum-time="${JOURNAL_KEEP_DAYS}d"
    run_optional journalctl --vacuum-size="$JOURNAL_MAX_SIZE"
else
    echo "未检测到 journalctl，跳过"
fi

section "9. 清理 systemd coredump 崩溃转储"
if [[ -d /var/lib/systemd/coredump ]]; then
    safe_find_delete "/var/lib/systemd/coredump" 3
else
    echo "未发现 /var/lib/systemd/coredump，跳过"
fi

section "10. 清理 /var/crash"
if [[ -d /var/crash ]]; then
    delete_all_inside_dir "/var/crash"
else
    echo "未发现 /var/crash，跳过"
fi

section "11. 清理临时目录"
safe_find_delete "/tmp" "$TMP_KEEP_DAYS"
safe_find_delete "/var/tmp" "$VAR_TMP_KEEP_DAYS"

section "12. 使用 systemd-tmpfiles 清理系统临时文件"
if command -v systemd-tmpfiles >/dev/null 2>&1; then
    run_optional systemd-tmpfiles --clean
else
    echo "未检测到 systemd-tmpfiles，跳过"
fi

section "13. 清理旧日志压缩包和轮转日志"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] 将清理超过 ${OLD_LOG_KEEP_DAYS} 天的旧日志文件，预览前 200 条："
    find /var/log -xdev -type f \( \
        -name "*.gz" -o \
        -name "*.old" -o \
        -name "*.1" -o \
        -name "*.log.*" \
    \) -mtime +"$OLD_LOG_KEEP_DAYS" -print 2>/dev/null | head -n 200 || true
else
    find /var/log -xdev -type f \( \
        -name "*.gz" -o \
        -name "*.old" -o \
        -name "*.1" -o \
        -name "*.log.*" \
    \) -mtime +"$OLD_LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi

section "14. 大日志处理"
if [[ "$AGGRESSIVE_LOGS" -eq 1 ]]; then
    echo "已启用 --aggressive-logs，将截断超过 500M 的当前日志文件。"

    while IFS= read -r logfile; do
        echo "处理大日志：$logfile"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[DRY-RUN] 将截断：$logfile"
        else
            truncate -s 0 "$logfile" 2>/dev/null || true
        fi
    done < <(find /var/log -xdev -type f -size "$BIG_LOG_SIZE" 2>/dev/null)
else
    echo "默认不截断当前日志文件。"
    echo "如确实需要，可加参数：--aggressive-logs"
    echo "当前超过 500M 的日志文件预览："
    find /var/log -xdev -type f -size "$BIG_LOG_SIZE" -print 2>/dev/null || true
fi

section "15. 清理 Debian / Ubuntu 包管理旧缓存"
if [[ -d /var/cache/debconf ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将清理 /var/cache/debconf 下的 old 文件："
        find /var/cache/debconf -xdev -type f -name "*-old" -print 2>/dev/null || true
    else
        find /var/cache/debconf -xdev -type f -name "*-old" -delete 2>/dev/null || true
    fi
fi

delete_all_inside_dir "/var/lib/apt/lists/partial"
delete_all_inside_dir "/var/cache/apt/archives/partial"

section "16. 清理用户缓存、缩略图、回收站"
if [[ "$CLEAN_USER_CACHE" -eq 1 ]]; then
    while IFS= read -r user_home; do
        [[ -d "$user_home" ]] || continue

        echo "处理用户目录：$user_home"

        safe_find_delete "$user_home/.cache" "$USER_CACHE_KEEP_DAYS"

        delete_all_inside_dir "$user_home/.thumbnails"
        delete_all_inside_dir "$user_home/.cache/thumbnails"

        safe_find_delete "$user_home/.local/share/Trash/files" "$TRASH_KEEP_DAYS"
        safe_find_delete "$user_home/.local/share/Trash/info" "$TRASH_KEEP_DAYS"

        safe_find_delete "$user_home/.cache/pip" 7
        safe_find_delete "$user_home/.cache/pipenv" 7
        safe_find_delete "$user_home/.cache/pypoetry" 7

        safe_find_delete "$user_home/.npm/_cacache" 14
        safe_find_delete "$user_home/.cache/yarn" 14

        safe_find_delete "$user_home/.cache/fontconfig" 30
        safe_find_delete "$user_home/.cache/gvfs" 7
    done < <(list_user_homes)
else
    echo "已使用 --no-user-cache，跳过用户缓存清理。"
fi

section "17. 清理 Flatpak 未使用运行时"
if command -v flatpak >/dev/null 2>&1; then
    run_optional flatpak uninstall --unused -y
else
    echo "未安装 Flatpak，跳过"
fi

section "18. 清理 Snap 旧版本"
if command -v snap >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] 将尝试清理 Snap disabled 旧版本："
        LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' || true
    else
        LANG=C snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            if [[ -n "${snapname:-}" && -n "${revision:-}" ]]; then
                run_optional snap remove "$snapname" --revision="$revision"
            fi
        done
    fi
else
    echo "未安装 Snap，跳过"
fi

section "19. Docker 清理提示"
if command -v docker >/dev/null 2>&1; then
    echo "检测到 Docker。"
    echo "脚本默认不自动执行 Docker 深度清理，避免误删镜像、容器、构建缓存或数据库卷。"
    echo
    echo "手动清理未使用对象："
    echo "docker system prune"
    echo
    echo "更深度清理未使用镜像："
    echo "docker system prune -a"
    echo
    echo "不建议随便执行："
    echo "docker system prune -a --volumes"
    echo
    echo "因为 --volumes 可能删除数据库、服务数据卷。"
else
    echo "未安装 Docker，跳过"
fi

section "20. 检查可清理的大目录"
echo "根目录一级目录占用概览："
du -hxd1 / 2>/dev/null | sort -h | tail -n 20 || true

if [[ -d /var ]]; then
    echo
    echo "/var 一级目录占用概览："
    du -hxd1 /var 2>/dev/null | sort -h | tail -n 20 || true
fi

if [[ -d /home ]]; then
    echo
    echo "/home 一级目录占用概览："
    du -hxd1 /home 2>/dev/null | sort -h | tail -n 20 || true
fi

section "清理后磁盘占用"
df -h || true

echo
echo "=================================================="
echo "系统更新与清理完成"
echo "=================================================="

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "当前是预览模式，没有实际升级或删除。"
    echo "确认无误后可执行："
    echo "sudo bash $0"
fi

if [[ -f /var/run/reboot-required ]]; then
    echo
    echo "提示：系统更新后需要重启。"
    echo "建议执行："
    echo "sudo reboot"
fi

if [[ -n "${LOG_FILE:-}" && "$DRY_RUN" -eq 0 ]]; then
    echo
    echo "本次运行日志：$LOG_FILE"
fi

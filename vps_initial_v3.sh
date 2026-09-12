#!/usr/bin/env bash
# VPS 自动初始化部署脚本 v3（Debian/Ubuntu）
# 请以 root 身份执行：bash vps_initial_v3.sh

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
trap 'die "第 ${LINENO} 行执行失败，请检查上面的输出。"' ERR

[[ ${EUID:-$(id -u)} -eq 0 ]] || die '请以 root 身份运行此脚本。'
command -v apt-get >/dev/null 2>&1 || die '未找到 apt-get；此脚本适用于 Debian/Ubuntu。'

log '设置 root 密码'
while :; do
    IFS= read -r -s -p '请输入 VPS 新 root 密码：' ROOT_PASSWORD
    printf '\n'
    IFS= read -r -s -p '请再次输入 VPS 新 root 密码：' ROOT_PASSWORD_CONFIRM
    printf '\n'
    [[ -n "$ROOT_PASSWORD" ]] || { printf '%s\n' '密码不能为空，请重新输入。'; continue; }
    [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] && break
    printf '%s\n' '两次密码不一致，请重新输入。'
done
# 通过标准输入传给 chpasswd，特殊字符不会被 shell 再解释；密码不会写入命令行。
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
unset ROOT_PASSWORD ROOT_PASSWORD_CONFIRM

log '安装基本工具和 cron'
apt-get update
apt-get install -y sudo wget bash curl unzip cron ca-certificates

# Require a valid HTTPS certificate and replace files atomically after download.
download_https() {
    # 在 set -u 下必须先分别赋值，再拼接临时文件名；否则 destination
    # 会在同一条 local 声明中被提前展开而触发 unbound variable。
    local url destination temporary
    url=${1:?缺少下载地址}
    destination=${2:?缺少目标路径}
    temporary="${destination}.tmp.$$"
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$temporary" "$url"
    chmod 755 "$temporary"
    mv -f -- "$temporary" "$destination"
}

log '安装 DNS 优化脚本并运行'
download_https https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/dns_opt.sh /root/dns_opt.sh
bash /root/dns_opt.sh

log '安装 BBR 优化脚本并运行'
install -d /opt
download_https https://github.com/teddysun/across/raw/master/bbr.sh /opt/bbr.sh
# bbr.sh 会从终端读取一次“开始”按键，并在需要时询问是否重启；按提示操作即可。
/opt/bbr.sh

log '运行 TCP 优化脚本（下面会要求输入内存、带宽和 RTT）'
NET_TCP_TUNE_URL="${NET_TCP_TUNE_URL:-https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/net-tcp-tunev3.sh}"
download_https "$NET_TCP_TUNE_URL" /root/net-tcp-tunev3.sh
bash /root/net-tcp-tunev3.sh

log '安装 vnStat'
download_https https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/install_vnstat.sh /root/install_vnstat.sh
bash /root/install_vnstat.sh

log '安装限流关机脚本'
download_https https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/auto_shutdown.sh /root/auto_shutdown.sh

while :; do
    read -r -p '请输入每月流量上限（GB，至少 10 的整数）：' MONTH_LIMIT
    if [[ "$MONTH_LIMIT" =~ ^[1-9][0-9]*$ ]] && (( MONTH_LIMIT >= 10 )); then
        break
    fi
    printf '%s\n' '请输入大于或等于 10 的整数。'
done
DAY_LIMIT=$((MONTH_LIMIT / 10))
# 只替换目标变量所在的赋值行，保留远程脚本其余内容不变。
sed -i \
    -e "s/^TRAFF_MONTH_TOTAL_GiB=.*/TRAFF_MONTH_TOTAL_GiB=${MONTH_LIMIT}/" \
    -e "s/^TRAFF_DAY_TOTAL_GiB=.*/TRAFF_DAY_TOTAL_GiB=${DAY_LIMIT}/" \
    /root/auto_shutdown.sh
printf '已设置月限流：%s GB；日限流：%s GB（按月限流/10 向下取整，最小为 1）。\n' "$MONTH_LIMIT" "$DAY_LIMIT"

log '启用 cron 并写入定时任务'
systemctl enable --now cron
CRON_TMP=$(mktemp)
trap 'rm -f "$CRON_TMP"' EXIT
(crontab -l 2>/dev/null || true) > "$CRON_TMP"
grep -Fqx '*/2 * * * * /root/auto_shutdown.sh > /root/templog.txt 2>&1' "$CRON_TMP" || \
    printf '%s\n' '*/2 * * * * /root/auto_shutdown.sh > /root/templog.txt 2>&1' >> "$CRON_TMP"
grep -Fqx '5 3 1 * * /sbin/shutdown -r now' "$CRON_TMP" || \
    printf '%s\n' '5 3 1 * * /sbin/shutdown -r now' >> "$CRON_TMP"
crontab "$CRON_TMP"
rm -f "$CRON_TMP"
trap - EXIT

log '下载防火墙脚本（先跳过交互面板，不自动修改防火墙规则）'
download_https https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/firewall_nft_manager.sh /root/firewall_nft_manager.sh
download_https https://raw.githubusercontent.com/AthesFrey/VPS_sh/main/nft_conn_report.sh /root/nft_conn_report.sh

cat <<'EOF2'

============================================================
VPS 初始化已完成。

防火墙脚本已经下载到：
  /root/firewall_nft_manager.sh
  /root/nft_conn_report.sh

请确认 SSH 备用登录方式可用后，再手动运行：
  bash /root/firewall_nft_manager.sh
然后按脚本提示设置防火墙规则。
============================================================
EOF2

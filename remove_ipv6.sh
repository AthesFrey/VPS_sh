#!/usr/bin/env bash
set -Eeuo pipefail

# 1) 要求 root
if [[ $EUID -ne 0 ]]; then
  echo "请以 root 运行（例如：sudo -i 后再执行）。"
  exit 1
fi

# 2) 变量
CONF=/etc/sysctl.conf
BK="$CONF.bak.$(date +%F-%H%M%S)"
vars=(
  "net.ipv6.conf.all.disable_ipv6"
  "net.ipv6.conf.default.disable_ipv6"
  "net.ipv6.conf.lo.disable_ipv6"
)
value=1

# 3) 备份
if [[ -f "$CONF" ]]; then
  cp -a "$CONF" "$BK"
  echo "已备份到 $BK"
else
  touch "$CONF"
fi

# 4) 删除所有旧定义（包括被注释的保持不变，只删真正的配置行）
for v in "${vars[@]}"; do
  # 删除以变量开头且包含 '=' 的非注释行
  sed -i "/^[[:space:]]*${v}[[:space:]]*=/ {/^[[:space:]]*#/!d}" "$CONF"
done

# 5) 统一追加正确值
{
  echo ""
  echo "# ---- disable IPv6 (added by script at $(date)) ----"
  for v in "${vars[@]}"; do
    echo "${v} = ${value}"
  done
} >> "$CONF"

# 6) 重新加载（仅加载这个文件）
sysctl -p "$CONF"

# 7) 验证
echo "当前内核开关："
sysctl net.ipv6.conf.{all,default,lo}.disable_ipv6
echo "检查 IPv6 地址："
if ip -6 addr show | grep -q "inet6"; then
  ip -6 addr show
  echo "提示：若仍见到旧地址，可重启网络服务或重启系统。"
else
  echo "OK：未发现 inet6 地址。"
fi

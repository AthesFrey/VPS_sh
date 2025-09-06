#!/usr/bin/env bash
set -Eeuo pipefail

# 1) 要求 root
if [[ ${EUID:-$(id -u)}"x" != "0x" ]]; then
  echo "请以 root 运行（例如：sudo -i 后再执行）。"
  exit 1
fi

# 2) 变量
CONF=/etc/sysctl.conf                 # 如需切到 sysctl.d，可改成：/etc/sysctl.d/999-ipv6-disable.conf
BK="$CONF.bak.$(date +%F-%H%M%S)"
BEGIN_TAG="# BEGIN ipv6-disable (managed)"
END_TAG="# END ipv6-disable (managed)"
vars=(
  "net.ipv6.conf.all.disable_ipv6"
  "net.ipv6.conf.default.disable_ipv6"
  "net.ipv6.conf.lo.disable_ipv6"
)
value=1

# 3) 备份与确保文件存在
if [[ -f "$CONF" ]]; then
  cp -a -- "$CONF" "$BK"
  echo "已备份到 $BK"
else
  install -m 0644 /dev/null "$CONF"
fi

# 4) 移除旧的“管理块”（BEGIN/END 之间的内容）
tmp="$(mktemp)"
awk -v b="$BEGIN_TAG" -v e="$END_TAG" '
  BEGIN { inblk=0 }
  $0==b { inblk=1; next }
  $0==e { inblk=0; next }
  { if (!inblk) print $0 }
' "$CONF" > "$tmp"
mv -- "$tmp" "$CONF"

# 5) 清理散落旧定义（非注释的真实配置行）
#    注意：点号需要转义为 \. 以免误匹配
for v in "${vars[@]}"; do
  v_esc="${v//./\\.}"  # 仅转义点号，足够覆盖本场景
  # 删掉以变量名开头（可带空白）且出现 "=" 的非注释行
  # -E 扩展正则更直观；仅删除匹配到的那一行
  sed -Ei "/^[[:space:]]*${v_esc}[[:space:]]*=/ { /^[[:space:]]*#/!d; }" "$CONF"
done

# 6) 追加全新的管理块（幂等：旧块已在步骤4清理）
{
  echo ""
  echo "$BEGIN_TAG"
  echo "# 写入时间: $(date -Is)"
  for v in "${vars[@]}"; do
    echo "${v} = ${value}"
  done
  echo "$END_TAG"
} >> "$CONF"

# 7) 重新加载（仅加载这个文件；若用 sysctl.d，请改为 sysctl --system）
#    在无 IPv6 内核/节点时可能会报错，这里容忍为非致命
if ! sysctl -p "$CONF" >/dev/null 2>&1; then
  echo "提示：sysctl -p 返回非零（可能是系统未启用 IPv6 内核组件），已忽略。"
fi

# 8) 验证
echo "当前内核开关："
sysctl net.ipv6.conf.{all,default,lo}.disable_ipv6 2>/dev/null || true

echo "检查 IPv6 地址："
if ip -6 addr show 2>/dev/null | grep -qE '\binet6\b'; then
  ip -6 addr show
  echo "提示：若仍见到旧地址，可重启网络服务或重启系统；部分服务需重启后完全释放 IPv6。"
else
  echo "OK：未发现 inet6 地址。"
fi

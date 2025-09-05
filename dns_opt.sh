#!/usr/bin/env bash
# dns_opt.sh — Minimal DNS optimizer (no kernel/netfilter tweaks)
# 目标：基于当前 resolv.conf 优化 DNS；不改内核、不动防火墙。
# 用法：
#   bash dns_opt.sh
# 可选环境变量：
#   DNS_EXTRA="1.1.1.1 8.8.8.8 9.9.9.9"  追加的公共DNS
#   KEEP_EXISTING=1                      1=保留现有DNS在前(默认)，0=只用公共DNS
#   PERSIST=1                            对 systemd-resolved 写drop-in并重启(默认1；设0只运行时生效)
#   OPTS="single-request-reopen timeout:2 attempts:2 rotate"  resolv.conf 的 options

set -euo pipefail

DNS_EXTRA="${DNS_EXTRA:-"1.1.1.1 8.8.8.8 9.9.9.9"}"
KEEP_EXISTING="${KEEP_EXISTING:-1}"
PERSIST="${PERSIST:-1}"
OPTS="${OPTS:-"single-request-reopen timeout:2 attempts:2 rotate"}"

ts() { date +%F-%T; }
log() { echo "[$(ts)] $*"; }

# 读取当前 resolv.conf（无论是否被 resolved 接管都先取一份原始nameserver）
if [[ -L /etc/resolv.conf ]]; then
  RESOLV_REAL="$(readlink -f /etc/resolv.conf)"
else
  RESOLV_REAL="/etc/resolv.conf"
fi
[[ -f "$RESOLV_REAL" ]] || { log "未找到 $RESOLV_REAL"; exit 1; }

# 提取现有 nameserver
mapfile -t EXISTING < <(grep -E '^\s*nameserver\s+' "$RESOLV_REAL" | awk '{print $2}' | tr -d '\r' | sed '/^$/d' | uniq)
# 过滤出看起来像 IPv4/IPv6 的条目
VALID=()
for ip in "${EXISTING[@]:-}"; do
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" =~ : ]]; then
    VALID+=("$ip")
  fi
done

# 组装目标 DNS 列表
FINAL=()
if [[ "${KEEP_EXISTING}" = "1" && "${#VALID[@]}" -gt 0 ]]; then
  FINAL+=("${VALID[@]}")
fi
# 追加公共DNS，避免重复
for ip in $DNS_EXTRA; do
  skip=0
  for ex in "${FINAL[@]:-}"; do [[ "$ip" == "$ex" ]] && { skip=1; break; }; done
  [[ $skip -eq 0 ]] && FINAL+=("$ip")
done

if [[ "${#FINAL[@]}" -eq 0 ]]; then
  # 兜底：至少给两条
  FINAL=("1.1.1.1" "8.8.8.8")
fi

log "目标 DNS 列表：${FINAL[*]}"

# 判断是否为 systemd-resolved 管理
IS_STUB=0
if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q 'systemd'; then
  IS_STUB=1
fi

if [[ $IS_STUB -eq 1 ]] && command -v resolvectl >/dev/null 2>&1; then
  # 使用 systemd-resolved 的做法
  # 选默认出口网卡
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "$IFACE" ]] || IFACE="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')"
  if [[ -z "$IFACE" ]]; then
    log "未能识别默认路由网卡，尝试对全局生效（可能需要手动调整）"
    IFACE="";  # resolvectl 需要接口名，这里留空只做持久化写入
  fi

  if [[ -n "$IFACE" ]]; then
    log "检测到 systemd-resolved；设置接口 $IFACE 的 DNS（运行时）"
    resolvectl dns     "$IFACE" ${FINAL[*]} || true
    resolvectl domains "$IFACE" '~.'        || true   # 设为缺省域路由
    resolvectl flush-caches || true
  fi

  if [[ "$PERSIST" = "1" ]]; then
    # 写 drop-in 以持久化
    mkdir -p /etc/systemd/resolved.conf.d
    {
      echo "[Resolve]"
      printf "DNS=%s\n" "${FINAL[*]}"
      echo "DNSSEC=allow-downgrade"
      echo "Cache=yes"
      echo "ReadEtcHosts=yes"
    } >/etc/systemd/resolved.conf.d/10-dns-opt.conf

    systemctl restart systemd-resolved
    log "已写入 /etc/systemd/resolved.conf.d/10-dns-opt.conf 并重启 systemd-resolved"
  else
    log "PERSIST=0：仅运行时生效，不写入持久化配置"
  fi

  # 展示当前状态
  resolvectl status | sed -n '1,80p' || true

else
  # 非 systemd-resolved：直接改 /etc/resolv.conf（先备份一次）
  BAK="/etc/resolv.conf.bak.$(date +%F-%H%M%S)"
  cp -a /etc/resolv.conf "$BAK"
  log "已备份 /etc/resolv.conf 到 $BAK"

  {
    for ip in "${FINAL[@]}"; do
      echo "nameserver $ip"
    done
    # 写入 options（幂等，覆盖旧 options）
    echo -n "options"
    for o in $OPTS; do echo -n " $o"; done
    echo
  } >/etc/resolv.conf

  log "已写入优化后的 /etc/resolv.conf"
  log "内容如下："
  cat /etc/resolv.conf
fi

log "DNS 优化完成。你可以用：getent ahostsv4 addons.mozilla.org && dig +short google.com @${FINAL[0]} 进行快速验证（如已安装 dig）。"

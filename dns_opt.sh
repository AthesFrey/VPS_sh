#!/usr/bin/env bash
# dns_opt.sh — Minimal DNS optimizer (no kernel/netfilter tweaks)
# 目标：基于当前 resolv.conf 优化 DNS；不改内核、不动防火墙。
# 用法：直接运行；支持多次运行无副作用
# 环境变量：
#   DNS_EXTRA="1.1.1.1 8.8.8.8 9.9.9.9"   # 追加的公共 DNS
#   KEEP_EXISTING=1                       # 1=保留现有 DNS 在前(默认)，0=只用公共 DNS
#   PERSIST=1                             # 1=写入 systemd-resolved drop-in 并重启（默认）；0=仅运行时生效
#   OPTS="single-request-reopen timeout:2 attempts:2 rotate"  # resolv.conf options

set -euo pipefail

DNS_EXTRA="${DNS_EXTRA:-"1.1.1.1 8.8.8.8 9.9.9.9"}"
KEEP_EXISTING="${KEEP_EXISTING:-1}"
PERSIST="${PERSIST:-1}"
OPTS="${OPTS:-"single-request-reopen timeout:2 attempts:2 rotate"}"

ts() { date +%F-%T; }
log() { echo "[$(ts)] $*"; }

# 找到真正读取用的 resolv.conf
if [[ -L /etc/resolv.conf ]]; then
  RESOLV_REAL="$(readlink -f /etc/resolv.conf)"
else
  RESOLV_REAL="/etc/resolv.conf"
fi
[[ -f "$RESOLV_REAL" ]] || { log "未找到 $RESOLV_REAL"; exit 1; }

# 提取现有 nameserver
mapfile -t EXISTING < <(grep -E '^\s*nameserver\s+' "$RESOLV_REAL" | awk '{print $2}' | tr -d '\r' | sed '/^$/d' | uniq)

# 过滤 IPv4/IPv6
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
for ip in $DNS_EXTRA; do
  skip=0
  for ex in "${FINAL[@]:-}"; do
    [[ "$ip" == "$ex" ]] && { skip=1; break; }
  done
  [[ $skip -eq 0 ]] && FINAL+=("$ip")
done
if [[ "${#FINAL[@]}" -eq 0 ]]; then
  FINAL=("1.1.1.1" "8.8.8.8")
fi
log "目标 DNS 列表：${FINAL[*]}"

# 判断是否为 systemd-resolved 管理
IS_STUB=0
if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q 'systemd'; then
  IS_STUB=1
fi

if [[ $IS_STUB -eq 1 ]] && command -v resolvectl >/dev/null 2>&1; then
  # 使用 systemd-resolved
  IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
  [[ -n "${IFACE:-}" ]] || IFACE="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')"

  if [[ -n "${IFACE:-}" ]]; then
    log "检测到 systemd-resolved；设置接口 ${IFACE} 的 DNS（运行时）"
    resolvectl dns "${IFACE}" "${FINAL[@]}" || true
    # 注意是单数 domain
    resolvectl domain "${IFACE}" '~.' || true   # 将此链路作为默认域路由
    resolvectl flush-caches || true
  else
    log "未能识别默认路由网卡，将仅写入持久化配置（如启用 PERSIST）"
  fi

  if [[ "$PERSIST" = "1" ]]; then
    mkdir -p /etc/systemd/resolved.conf.d
    # 以 here-doc 写入，避免分号/换行问题
    {
      printf "[Resolve]\n"
      printf "DNS=%s\n" "${FINAL[*]}"
      printf "DNSSEC=allow-downgrade\n"
      printf "Cache=yes\n"
      printf "ReadEtcHosts=yes\n"
    } > /etc/systemd/resolved.conf.d/10-dns-opt.conf

    systemctl restart systemd-resolved
    log "已写入 /etc/systemd/resolved.conf.d/10-dns-opt.conf 并重启 systemd-resolved"
  else
    log "PERSIST=0：仅运行时生效，不写入持久化配置"
  fi

  resolvectl status | sed -n '1,80p' || true

else
  # 非 systemd-resolved：直接改 /etc/resolv.conf（仅在内容变化时备份与覆盖）
  TARGET_CONTENT="$(mktemp)"
  {
    for ip in "${FINAL[@]}"; do
      echo "nameserver $ip"
    done
    echo -n "options"
    for o in $OPTS; do
      echo -n " $o"
    done
    echo
  } > "$TARGET_CONTENT"

  # 若内容无变化，则不动；有变化才备份+写入
  if ! cmp -s "$TARGET_CONTENT" /etc/resolv.conf; then
    BAK="/etc/resolv.conf.bak.$(date +%F-%H%M%S)"
    cp -a /etc/resolv.conf "$BAK" || true
    cat "$TARGET_CONTENT" > /etc/resolv.conf
    log "已写入优化后的 /etc/resolv.conf（备份：$BAK）"
  else
    log "/etc/resolv.conf 内容无变化，跳过写入与备份"
  fi
  rm -f "$TARGET_CONTENT"
  log "当前 /etc/resolv.conf 内容："
  cat /etc/resolv.conf
fi

log "完成。可快速自检：getent ahostsv4 addons.mozilla.org && dig +short google.com @${FINAL[0]}（如已安装 dig）"

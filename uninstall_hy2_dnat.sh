#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[ERR] 请用 root 运行（sudo -i 后再执行）" >&2
    exit 1
  fi
}

log() { echo -e "[*] $*"; }
warn(){ echo -e "[!] $*" >&2; }

# 删除某条链中，所有包含指定关键字(通常是 comment)的规则
# 使用 line-numbers 倒序删除，避免行号变化导致误删/漏删
purge_iptables_rules_by_keyword() {
  local bin="$1"   # iptables 或 ip6tables
  local table="$2" # nat
  local chain="$3" # PREROUTING
  local keyword="$4"

  if ! command -v "$bin" >/dev/null 2>&1; then
    warn "$bin 不存在，跳过"
    return 0
  fi

  log "清理 $bin -t $table $chain 中包含关键字：$keyword 的规则…"

  # 多轮循环：即使某些系统输出格式不同/删除中断，也尽量删干净
  local round=0
  while true; do
    round=$((round+1))
    # 取所有匹配行的行号，按倒序删
    mapfile -t nums < <("$bin" -t "$table" -L "$chain" -n --line-numbers 2>/dev/null \
      | awk -v kw="$keyword" 'index($0, kw){print $1}' \
      | sort -rn)

    if [[ ${#nums[@]} -eq 0 ]]; then
      log "未发现匹配规则（或已清理完成）。"
      break
    fi

    log "第 $round 轮：将删除 ${#nums[@]} 条规则（倒序）…"
    for n in "${nums[@]}"; do
      # -w 3 可能在少数 iptables 版本不可用，所以失败就回退不带 -w
      "$bin" -w 3 -t "$table" -D "$chain" "$n" 2>/dev/null || \
      "$bin" -t "$table" -D "$chain" "$n" 2>/dev/null || true
    done

    # 安全阈值，防止异常环境死循环
    if (( round >= 20 )); then
      warn "已循环 20 轮仍有残留（可能有并发修改或异常输出），请手动检查：$bin -t $table -S $chain"
      break
    fi
  done
}

main() {
  require_root

  log "1) 停止并禁用 hy2-dnat.service（如存在）"
  systemctl stop hy2-dnat.service 2>/dev/null || true
  systemctl disable hy2-dnat.service 2>/dev/null || true
  systemctl reset-failed hy2-dnat.service 2>/dev/null || true

  log "2) 删除 systemd/unit 与参数文件、脚本文件"
  rm -f /etc/systemd/system/hy2-dnat.service
  rm -f /etc/default/hy2-dnat
  rm -f /root/hy2-dnat.sh

  log "3) 重新加载 systemd"
  systemctl daemon-reload || true

  log "4) 清理旧的 NAT PREROUTING 规则（按 comment 关键字删除）"
  purge_iptables_rules_by_keyword iptables  nat PREROUTING "HY2 REDIRECT autoload"
  purge_iptables_rules_by_keyword ip6tables nat PREROUTING "HY2 REDIRECT autoload"

  log "5) 验证（输出剩余的相关规则，应为空）"
  (iptables  -t nat -S PREROUTING 2>/dev/null | grep -F "HY2 REDIRECT autoload") || echo "[OK] IPv4: 无残留"
  (ip6tables -t nat -S PREROUTING 2>/dev/null | grep -F "HY2 REDIRECT autoload") || echo "[OK] IPv6: 无残留"

  log "完成 ✅（未修改 UFW 端口放行规则）"
  warn "注意：安装脚本曾 disable netfilter-persistent，但本卸载脚本不会帮你恢复它的启用状态（避免误改你的原配置）。"
}

main "$@"

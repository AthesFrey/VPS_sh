#!/usr/bin/env bash
# safe_nft_setup.sh — Minimal, idempotent nftables setup with conn logging
# 说明：
# - 不触碰 iptables(-nft) 管理的 ipv4/ipv6 表；仅使用 table inet
# - 可多次执行：自动备份当前 ruleset，并清理重复定义的 *.nft
# - MODE: permissive | hardened（默认 permissive）
# - ALLOW_TCP_PORTS / ALLOW_UDP_PORTS: 逗号分隔端口集合
# - 生成：
#     /etc/nftables.conf                # 主入口（include 目录）
#     /etc/nftables.d/10-baseline.nft   # 基线规则（按 MODE）
#     /etc/nftables.d/20-connlog.nft    # 连接日志（先于基线，限速，排除常见端口）

set -euo pipefail

# ---------------- 用户可调参数 ----------------
MODE="${MODE:-permissive}"                       # permissive | hardened
ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-22,80,443}"  # 逗号分隔；默认必含 22,80,443
ALLOW_UDP_PORTS="${ALLOW_UDP_PORTS:-}"           # 逗号分隔；为空则不声明 UDP 集合

# ---------------- 固定路径与工具检测 ----------------
MAIN_CONF="/etc/nftables.conf"
INC_DIR="/etc/nftables.d"
BASE_INC="$INC_DIR/10-baseline.nft"
LOG_INC="$INC_DIR/20-connlog.nft"
NEW_MAIN="$MAIN_CONF.new"
BACKUP_DIR="/root"
TS="$(date -Iseconds)"
BACKUP_RULESET="$BACKUP_DIR/nftables.backup.${TS}.nft"
PURGE_BAK_DIR="$BACKUP_DIR/nft_dedup_${TS}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need nft
need systemctl || true

mkdir -p "$INC_DIR"

# ---------------- 0) 备份当前 ruleset ----------------
if nft list ruleset >"$BACKUP_RULESET" 2>/dev/null; then
  echo "[i] backup ruleset -> $BACKUP_RULESET"
else
  echo "[w] cannot dump current ruleset (non-fatal)"
fi

# ---------------- 1) 主入口（仅 include） ----------------
cat >"$NEW_MAIN" <<'EOF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.nft"
EOF

# ---------------- 2) 解析端口集合（转为 nft set elements） ----------------
IFS=, read -r -a TCP_ARR <<<"${ALLOW_TCP_PORTS//[[:space:]]/}"
IFS=, read -r -a UDP_ARR <<<"${ALLOW_UDP_PORTS//[[:space:]]/}"

to_set_elems() {
  local -n _arr=$1
  local out=""
  for p in "${_arr[@]}"; do
    [[ -n "$p" ]] && out+="${p}, "
  done
  out="${out%%, }"
  printf "%s" "$out"
}

TCP_SET="$(to_set_elems TCP_ARR)"
UDP_SET="$(to_set_elems UDP_ARR)"

# 保底，避免空集合导致语法异常
if [[ -z "$TCP_SET" ]]; then
  TCP_SET="22,80,443"
fi

# ---------------- 3) 目录去重：移走任何“重复定义 baseline/connlog”的文件 ----------------
# 目的：防止 include 通配符把历史残留的 *.nft 一起加载，造成 “File exists”
mkdir -p "$PURGE_BAK_DIR"
shopt -s nullglob
for f in "$INC_DIR"/*.nft; do
  if grep -qE '^\s*table\s+inet\s+(baseline|connlog)\b' "$f"; then
    base="$(basename "$f")"
    # 我们会重写 10-baseline.nft 与 20-connlog.nft，因此把所有含上述两表的文件先备份并移走
    cp -a "$f" "$PURGE_BAK_DIR/$base"
    rm -f "$f"
  fi
done
shopt -u nullglob
echo "[i] dedup moved to: $PURGE_BAK_DIR"

# ---------------- 4) 写入 baseline（按 MODE） ----------------
if [[ "$MODE" == "hardened" ]]; then
  {
    echo "table inet baseline {"
    echo "  set allowed_tcp_ports { type inet_service; elements = { ${TCP_SET} } }"
    if [[ -n "$UDP_SET" ]]; then
      echo "  set allowed_udp_ports { type inet_service; elements = { ${UDP_SET} } }"
    fi
    cat <<'EOS'
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    ct state invalid drop
    iifname "lo" accept
    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept
EOS
    echo '    tcp dport @allowed_tcp_ports accept'
    if [[ -n "$UDP_SET" ]]; then
      echo '    udp dport @allowed_udp_ports accept'
    fi
    # Docker 通道（如不需要可注释）
    echo '    iifname "docker0" accept'
    echo '    oifname "docker0" accept'
    cat <<'EOS'
    # 兜底日志（被 drop 前记录少量）
    limit rate 2/second burst 10 packets log prefix "drop " flags all
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOS
  } >"$BASE_INC"
else
  {
    echo "table inet baseline {"
    echo "  set allowed_tcp_ports { type inet_service; elements = { ${TCP_SET} } }"
    if [[ -n "$UDP_SET" ]]; then
      echo "  set allowed_udp_ports { type inet_service; elements = { ${UDP_SET} } }"
    fi
    cat <<'EOS'
  chain input {
    type filter hook input priority 0; policy accept;
    ct state invalid drop
    iifname "lo" accept
    ct state established,related accept
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOS
  } >"$BASE_INC"
fi

# ---------------- 5) 写入 connlog（优先级更早，先于 baseline 记日志；TCP/UDP 分流） ----------------
# UDP 排除集合：若 UDP_SET 为空则用 TCP_SET 兜底，避免空集合
CONN_UDP_EXCLUDE="${UDP_SET:+${UDP_SET}, }${TCP_SET}"

cat >"$LOG_INC" <<EOF
table inet connlog {
  chain input {
    type filter hook input priority -100; policy accept;

    # 仅记录“新建 TCP 连接”，排除常见端口，避免噪声；不改变判决
    iifname != "lo" ct state new tcp dport != { ${TCP_SET} } \
      limit rate 20/second burst 40 packets \
      log prefix "conn " flags all counter

    # 仅记录“新建 UDP 连接”，排除常见/自定端口；不改变判决
    iifname != "lo" ct state new udp dport != { ${CONN_UDP_EXCLUDE} } \
      limit rate 10/second burst 20 packets \
      log prefix "conn " flags all counter
  }
}
EOF

# ---------------- 6) 语法检查 -> 安装 -> 加载 ----------------
echo "[i] syntax-check $NEW_MAIN ..."
nft -c -f "$NEW_MAIN"

# 只在语法通过时替换主文件
install -m 0644 "$NEW_MAIN" "$MAIN_CONF"

# 启用服务并加载
if systemctl enable --now nftables 2>/dev/null; then
  :
else
  echo "[w] systemd nftables service not available or not enabled (non-fatal)"
fi

nft -f "$MAIN_CONF"

echo "[i] nftables loaded. Existing tables:"
nft list tables || true

# ---------------- 7) journald：持久化与限额（防止日志刷爆） ----------------
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-connlog.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF

systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=500M >/dev/null 2>&1 || true

echo "[OK] Done. MODE=${MODE}. Files: $BASE_INC, $LOG_INC"
echo "[TIP] You can verify: nft list chain inet connlog input ; journalctl -k -S 'today 00:00:00' | grep -E 'conn |drop ' --color=auto"

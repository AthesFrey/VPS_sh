#!/usr/bin/env bash
# safe_nft_setup_v2.sh — "Secure out-of-the-box" firewall script
set -euo pipefail

MODE="${MODE:-permissive}"                # permissive | hardened
ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-22,80,443}"  # 逗号分隔
ALLOW_UDP_PORTS="${ALLOW_UDP_PORTS:-}"           # 逗号分隔（为空则不声明集合）
MAIN_CONF="/etc/nftables.conf"
INC_DIR="/etc/nftables.d"
BASE_INC="$INC_DIR/10-baseline.nft"
LOG_INC="$INC_DIR/20-connlog.nft"
NEW_MAIN="$MAIN_CONF.new"
BACKUP="/root/nftables.backup.$(date -Iseconds).nft"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
need nft
mkdir -p "$INC_DIR"

# 0) 备份当前规则集
nft list ruleset > "$BACKUP" || true
echo "[i] backup ruleset -> $BACKUP"

# 1) 主入口：只 include，不 flush
cat > "$NEW_MAIN" <<'EOF'
#!/usr/sbin/nft -f
include "/etc/nftables.d/*.nft"
EOF

# 2) 解析端口集合
IFS=, read -r -a TCP_ARR <<<"${ALLOW_TCP_PORTS//[[:space:]]/}"
IFS=, read -r -a UDP_ARR <<<"${ALLOW_UDP_PORTS//[[:space:]]/}"

to_set_elems() {
  local -n arr=$1
  local out=""
  for p in "${arr[@]}"; do
    [[ -n "$p" ]] && out+="${p}, "
  done
  out="${out%%, }"
  printf "%s" "$out"
}

TCP_SET=$(to_set_elems TCP_ARR)  # 至少有 22,80,443
UDP_SET=$(to_set_elems UDP_ARR)  # 可能为空

# 3) baseline：根据 MODE 生成；当 UDP_SET 为空时，不声明/不引用 UDP 集合
if [[ "${MODE}" == "hardened" ]]; then
  {
    echo "table inet baseline {"
    echo "  set allowed_tcp_ports { type inet_service; elements = { ${TCP_SET:-22,80,443} } }"
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
    echo "    tcp dport @allowed_tcp_ports accept"
    if [[ -n "$UDP_SET" ]]; then
      echo "    udp dport @allowed_udp_ports accept"
    fi
    # 若你确定有 Docker，可按需开启下行（不使用通配符，避免旧版 nft 兼容性问题）
    echo '    iifname "docker0" accept'
    echo '    oifname "docker0" accept'
    cat <<'EOS'
    limit rate 2/second burst 10 packets log prefix "drop " flags all
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOS
  } > "$BASE_INC"
else
  {
    echo "table inet baseline {"
    echo "  set allowed_tcp_ports { type inet_service; elements = { ${TCP_SET:-22,80,443} } }"
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
  chain forward { type filter hook forward priority 0; policy accept; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOS
  } > "$BASE_INC"
fi

# 4) connlog：仅日志，不改判决；为避免空集合，这里 UDP 排除集合至少用 TCP_SET 兜底
#    说明：我们仍然记录“新连接”，并对日志做限速；22/443 默认不记
CONN_UDP_EXCLUDE="${UDP_SET:+${UDP_SET}, }${TCP_SET:-22,80,443}"

cat > "$LOG_INC" <<EOF
table inet connlog {
  chain input {
    type filter hook input priority -100; policy accept;
    iifname != "lo" ct state new tcp dport != { ${TCP_SET:-22,80,443} } \
      limit rate 20/second burst 40 packets \
      log prefix "conn " flags all counter
    iifname != "lo" ct state new udp dport != { ${CONN_UDP_EXCLUDE} } \
      limit rate 10/second burst 20 packets \
      log prefix "conn " flags all counter
  }
}
EOF

# 5) 语法自检 -> 安装 -> 启用并加载
echo "[i] syntax-check $NEW_MAIN ..."
nft -c -f "$NEW_MAIN"

install -m 0644 "$NEW_MAIN" "$MAIN_CONF"
systemctl enable --now nftables
nft -f "$MAIN_CONF"

echo "[i] nftables loaded. Tables:"
nft list tables

# 6) journald：持久化与限额
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-connlog.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF
systemctl restart systemd-journald || true
journalctl --vacuum-size=500M || true

echo "[OK] Done. MODE=${MODE}. Files: $BASE_INC, $LOG_INC"

好的，已按 RTT=150ms 调整，仅把注释和缓冲上限从 16MB 提到 32MB（留出 \~18.8MB BDP 的余量）；其余参数保持不变：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 要求 root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Please run as root." >&2
  exit 1
fi

# 尝试加载 BBR（若为内置则无影响）
if command -v modprobe >/dev/null 2>&1; then
  modprobe tcp_bbr 2>/dev/null || true
fi

# 计算默认 IPv4 出口网卡（无则为空）
iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"

# 直接写入最终配置（加载顺序靠后，覆盖其它值）
# 注意：不依赖任何外部脚本或临时文件
cat >/etc/sysctl.d/999-net-bbr-fq.conf <<'EOF'
# Network TCP tuning for ~150ms RTT, 1GB RAM, 1Gbps
# Load-last override; safe on Ubuntu 22/24 and Debian 11/12/13+

# BBR + pacing（fq）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 健壮性与首包/恢复
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_moderate_rcvbuf = 1
# ECN 协商允许（遇到不兼容中间盒会回退）
net.ipv4.tcp_ecn = 1

# 缓冲上限（32MB），适配 ~18.8MB BDP（1Gbps×150ms），略留余量
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# 更安全的 TIME-WAIT 处理
net.ipv4.tcp_rfc1337 = 1

# rpf 宽松，避免多宿主/隧道被误杀（常见服务器建议）
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

# 设定权限（与发行版默认一致）
chmod 0644 /etc/sysctl.d/999-net-bbr-fq.conf

# 应用配置
sysctl --system >/dev/null

# 如有 tc 与默认网卡，则立即切换该网卡的根队列到 fq
if command -v tc >/dev/null 2>&1 && [ -n "${iface:-}" ]; then
  tc qdisc replace dev "$iface" root fq 2>/dev/null || true
fi

# 校验输出（仅回显关键值）
echo "---- VERIFY ----"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.core.rmem_max net.core.wmem_max
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen
sysctl net.ipv4.tcp_ecn net.ipv4.tcp_sack net.ipv4.tcp_timestamps
sysctl net.ipv4.tcp_rfc1337
if command -v tc >/dev/null 2>&1 && [ -n "${iface:-}" ]; then
  echo "qdisc on $iface:"
  tc qdisc show dev "$iface" || true
fi
echo "--------------"
```

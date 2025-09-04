# 以 root 执行
set -euxo pipefail

# 0) 记录出口网卡名（后面可能用到）
NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1); echo "NIC=$NIC"

# 1) 让系统解析优先走 IPv4（影响所有服务包含 shadowsocks/xray/sing-box 的出站解析）
cp -a /etc/gai.conf /etc/gai.conf.bak.$(date +%F) 2>/dev/null || true
grep -q '::ffff:0:0/96' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# 2) 用干净的公共 DNS（避免本地/IPv6 污染）。systemd-resolved/传统 resolv.conf 两种情况都覆盖
if command -v resolvectl >/dev/null 2>&1; then
  resolvectl dns "$NIC" 1.1.1.1 8.8.8.8
  resolvectl flush-caches
else
  cp -a /etc/resolv.conf /etc/resolv.conf.bak.$(date +%F) 2>/dev/null || true
  cat >/etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options edns0 trust-ad
EOF
fi

# 3) 开启 PMTU 黑洞自适应 + 合理 MSS，顺便上 BBR（更抗抖动）
cp -a /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F) 2>/dev/null || true
apply_sysctl(){ KEY="$1"; VAL="$2"; grep -q "^\s*${KEY}\b" /etc/sysctl.conf && \
  sed -i "s|^\s*${KEY}.*|${KEY} = ${VAL}|" /etc/sysctl.conf || echo "${KEY} = ${VAL}" >> /etc/sysctl.conf; }
apply_sysctl net.ipv4.tcp_mtu_probing 1
apply_sysctl net.ipv4.tcp_base_mss 1024
apply_sysctl net.ipv4.tcp_min_snd_mss 512
apply_sysctl net.core.rmem_max 16777216
apply_sysctl net.core.wmem_max 16777216
apply_sysctl net.ipv4.tcp_congestion_control bbr
sysctl -p

# 4) 在服务器侧“夹 MSS”，避免 TLS ClientHello/ServerHello 大包被路上丢（同时覆盖 IPv6）
apt-get update -y && apt-get install -y iptables-persistent || true
iptables  -t mangle -C OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || \
iptables  -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables  -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || \
iptables  -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -C OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || \
ip6tables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || \
ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
netfilter-persistent save

# 5) 重启你的代理服务（按你实际装的那一个）
systemctl restart sing-box 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
systemctl restart shadowsocks-libev 2>/dev/null || true
systemctl restart shadowsocks-rust 2>/dev/null || true

# 6) 快速自检（IPv4 能连即可；IPv6失败也没关系）
which curl >/dev/null 2>&1 && (curl -4I --max-time 8 https://www.tradingview.com || true)
which curl >/dev/null 2>&1 && (curl -6I --max-time 5 https://www.tradingview.com || true)
echo "DONE"

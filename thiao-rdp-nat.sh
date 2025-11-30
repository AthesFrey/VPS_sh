cat > /root/thiao-rdp-nat.sh <<'EOF'
#!/usr/bin/env bash
# thiao-rdp-nat.sh — 固化 8097 -> thiao:3389 DNAT，自动探测来宾 IP（libvirt default NAT）
# 需求：root 运行；宿主为 iptables-nft；libvirt 已安装；建议开启 ip_forward 持久化
set -euo pipefail

# -------- 可调参数 --------
VM="thiao"               # 你的虚机名
HOST_RDP_PORT=8097       # 宿主对外端口
GUEST_RDP_PORT=3389      # 来宾 RDP 端口（默认 3389）
NET_NAME="default"       # libvirt NAT 网络名（virbr0 对应的就是 default）
# -------------------------

# 0) 前置检查
if [[ $EUID -ne 0 ]]; then
  echo "[ERR] Please run as root." >&2
  exit 1
fi
command -v virsh >/dev/null || { echo "[ERR] virsh not found"; exit 1; }
command -v iptables >/dev/null || { echo "[ERR] iptables not found"; exit 1; }

echo "[INF] === thiao-rdp-nat start ==="

# 1) 等待 libvirtd 与网络就绪；确保 default 网络启动（修复：避免 already active 时报错退出/避免本地化导致误判）
until systemctl is-active --quiet libvirtd; do sleep 1; done

export LC_ALL=C
export LANG=C

is_net_active() {
  virsh net-info "$NET_NAME" 2>/dev/null | awk -F': *' '/^Active:/{print tolower($2)}' | grep -qx "yes"
}

if ! is_net_active; then
  echo "[INF] Starting libvirt network: $NET_NAME"
  # 修复点：stderr 也吞掉；并且即使遇到“already active”的竞态，也不中断脚本
  virsh net-start "$NET_NAME" >/dev/null 2>&1 || true
fi

# 再确认一次：如果最后还是没 active，才算真失败
is_net_active || { echo "[ERR] libvirt network '$NET_NAME' is not active."; exit 1; }

virbr_if=$(virsh net-info "$NET_NAME" | awk -F': *' '/Bridge name/{print $2}')
: "${virbr_if:=virbr0}"

# 2) 如你已设置 autostart，宿主起来后 VM 应自动运行；这里再等一会儿（必要时尝试启动）
for i in {1..60}; do
  state=$(virsh domstate "$VM" 2>/dev/null || true)
  [[ "$state" == "running" ]] && break
  [[ $i -eq 15 ]] && { echo "[INF] VM not running, try start: $VM"; virsh start "$VM" >/dev/null 2>&1 || true; }
  sleep 2
done
state=$(virsh domstate "$VM" 2>/dev/null || true)
[[ "$state" == "running" ]] || { echo "[ERR] VM '$VM' is not running."; exit 1; }

# 3) 外网网卡与 MAC 地址
EXT_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
MAC=$(virsh domiflist "$VM" | awk '$2=="network" && $3=="'"$NET_NAME"'" {print $5; exit}')
if [[ -z "${MAC:-}" ]]; then
  echo "[ERR] Cannot find NIC MAC on libvirt network '$NET_NAME' for VM '$VM'."; exit 1
fi

# 4) 自动探测来宾 IP：优先 DHCP 租约，其次 domifaddr
GUEST_IP=""
for i in {1..30}; do
  # virsh net-dhcp-leases: 1 Expiry, 2 MAC, 3 Proto, 4 IP/CIDR, 5 Hostname, 6 ClientID
  GUEST_IP=$(virsh net-dhcp-leases "$NET_NAME" 2>/dev/null | \
             awk -v m="$MAC" 'BEGIN{IGNORECASE=1} $2==m {ip=$4; sub(/\/.*/,"",ip); print ip; exit}')
  [[ -n "$GUEST_IP" ]] && break
  sleep 2
done
if [[ -z "$GUEST_IP" ]]; then
  # domifaddr（尽量不用 agent，避免未装 qemu-guest-agent 时拿不到）
  GUEST_IP=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {sub(/\/.*/,"",$4); print $4; exit}')
fi
[[ -n "$GUEST_IP" ]] || { echo "[ERR] cannot find guest ip for $VM"; exit 1; }

echo "[INF] External IF: $EXT_IF"
echo "[INF] Libvirt br : $virbr_if"
echo "[INF] Guest MAC  : $MAC"
echo "[INF] Guest IP   : $GUEST_IP"

# 5) 开启 IPv4 转发（持久化会在 10.5 单独设置）
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 6) 清理旧 DNAT（不限定网卡，删除所有指向该端口的历史规则，防止叠加）
while iptables -t nat -S PREROUTING | grep -F -- "--dport ${HOST_RDP_PORT}" >/dev/null 2>&1; do
  iptables -t nat -S PREROUTING | grep -F -- "--dport ${HOST_RDP_PORT}" | head -n1 | sed 's/^-A/iptables -t nat -D/' | bash || true
done

# 7) 新建 DNAT：公网 :HOST_RDP_PORT -> GUEST_IP:GUEST_RDP_PORT（插到链首，保证命中）
iptables -t nat -I PREROUTING 1 -p tcp --dport "${HOST_RDP_PORT}" \
  -j DNAT --to-destination "${GUEST_IP}:${GUEST_RDP_PORT}"

# 8) 出口伪装与 FORWARD 放行（若已存在则跳过；来宾 IP 变化时会新增针对新 IP 的规则）
iptables -t nat -C POSTROUTING -o "$virbr_if" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "$virbr_if" -j MASQUERADE

iptables -C FORWARD -p tcp -d "${GUEST_IP}" --dport "${GUEST_RDP_PORT}" -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 1 -p tcp -d "${GUEST_IP}" --dport "${GUEST_RDP_PORT}" -j ACCEPT
iptables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
iptables -I FORWARD 2 -m state --state ESTABLISHED,RELATED -j ACCEPT

# 9) （可选）若启用 UFW，同步路由放行规则到“当前来宾 IP:3389”
if command -v ufw >/dev/null 2>&1; then
  # 删除任何到 "any port 3389" 的旧路由放行，再加上精确到当前 Guest IP 的
  ufw --force route delete allow proto tcp from any to any   port "${GUEST_RDP_PORT}" >/dev/null 2>&1 || true
  ufw --force route allow  proto tcp from any to "${GUEST_IP}" port "${GUEST_RDP_PORT}" >/dev/null 2>&1 || true
fi

echo "[OK] DNAT ${HOST_RDP_PORT} -> ${GUEST_IP}:${GUEST_RDP_PORT}"
# 10) 小自检：打印命中计数
iptables -t nat -L PREROUTING -n -v | awk '/tcp dpt:'"${HOST_RDP_PORT}"'/{print "[CNT] PREROUTING hits:",$1,$2}'
echo "[INF] === thiao-rdp-nat done ==="
EOF

chmod +x /root/thiao-rdp-nat.sh
/root/thiao-rdp-nat.sh

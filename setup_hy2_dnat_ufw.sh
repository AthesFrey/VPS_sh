#!/usr/bin/env bash
# setup_hy2_dnat_ufw.sh (v5.1, Bookworm-ready)
# 目标：UFW 主控 + systemd 在 UFW 之后补一条 DNAT（HY2 客户端原生跳端口）
set -euo pipefail

cecho(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
wecho(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
eecho(){ printf "\033[1;31m%s\033[0m\n" "$*"; }

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { eecho "请用 root 运行"; exit 1; }; }
detect_ssh_port(){ awk '/^[Pp]ort[[:space:]]+[0-9]+/ {p=$2} END{print p?p:22}' /etc/ssh/sshd_config 2>/dev/null || echo 22; }
detect_debian_codename(){ . /etc/os-release 2>/dev/null || true; echo "${VERSION_CODENAME:-}"; }

maybe_disable_backports() {
  # 仅当用户在老系统且更新失败，并且选择允许时，才禁用 backports
  wecho "尝试禁用 *-backports 源（支持 .list 与 .sources）以绕过 apt 404……"
  # 注释 .list backports 行
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sed -i -E '/backports/ s/^[[:space:]]*deb/# &/; /backports/ s/^[[:space:]]*deb-src/# &/' "$f" || true
  done
  # Deb822 .sources：写 Enabled: no
  for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    grep -qi backports "$f" || continue
    awk '
      BEGIN{IGNORECASE=1}
      /^Enabled:/ { print "Enabled: no"; next }
      /^Suites:/ && $0 ~ /backports/ { print; print "Enabled: no"; next }
      { print }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  done
}

apt_update_smart() {
  wecho "[2/7] 更新软件源"
  if apt-get update -y; then
    return 0
  fi
  # 如果是 debian 12（bookworm），我们不去禁用 backports，提示用户检查网络/镜像即可
  local codename; codename="$(detect_debian_codename)"
  if [[ "$codename" =~ ^(bookworm|trixie)$ ]]; then
    eecho "apt-get update 失败（$codename）。请检查网络/镜像源或稍后重试（不建议动 backports）。"
    exit 1
  fi
  # 非 bookworm 才询问是否禁用 backports
  wecho "检测到非 bookworm 且 update 失败。是否尝试禁用 backports 后重试？(y/N)"
  read -r ans
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
    maybe_disable_backports
    apt-get update -y
  else
    eecho "未禁用 backports，apt 仍失败。请手动修复后重试。"
    exit 1
  fi
}


# ---------------- 主流程 ----------------
require_root
cecho "== HY2 DNAT + UFW 一键配置（Debian 12 / bookworm 友好） =="

DEFAULT_LISTEN="2567"
DEFAULT_RANGE="15000:18369"
DEFAULT_PROTO="udp"
SSH_PORT="$(detect_ssh_port)"

read -rp "HY2 监听端口（默认 ${DEFAULT_LISTEN}，仅数字）: " LISTEN_PORT
LISTEN_PORT="${LISTEN_PORT:-$DEFAULT_LISTEN}"
read -rp "端口跳跃范围（默认 ${DEFAULT_RANGE}，格式 15000:18369）: " RANGE
RANGE="${RANGE:-$DEFAULT_RANGE}"
read -rp "协议（udp/tcp，默认 ${DEFAULT_PROTO}，HY2 用 udp）: " PROTO
PROTO="${PROTO:-$DEFAULT_PROTO}"

# 是否让 UFW 同时放行端口段（默认 n：只放行监听口即可）
ALLOW_RANGE="n"
read -rp "UFW 是否同时放行端口段 ${RANGE}/${PROTO}（安全面更大）？(y/N): " allow_r
[[ "${allow_r:-N}" =~ ^[Yy]$ ]] && ALLOW_RANGE="y"

cecho "配置预览："
echo "  系统版本          : $(. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-unknown})"
echo "  SSH 端口          : ${SSH_PORT}/tcp"
echo "  HY2 监听端口      : ${LISTEN_PORT}/${PROTO}"
echo "  端口跳跃范围(入口): ${RANGE}/${PROTO}"
echo "  DNAT 映射         : ${RANGE}/${PROTO}  →  :${LISTEN_PORT}"
echo "  UFW 放行端口段    : ${ALLOW_RANGE}"
read -rp "确认执行？(y/N): " go
[[ "${go:-N}" =~ ^[Yy]$ ]] || { wecho "已取消。"; exit 0; }

# [1/7] 避免冲突
wecho "[1/7] 停用可能冲突的 netfilter-persistent（如不存在则忽略）"
systemctl disable --now netfilter-persistent 2>/dev/null || true
rm -f /etc/systemd/system/iptables.service /etc/systemd/system/ip6tables.service 2>/dev/null || true

# [2/7] 更新 & 安装
apt_update_smart
DEBIAN_FRONTEND=noninteractive apt-get install -y ufw iptables

# [3/7] UFW：放行 SSH / 监听口；端口段按需放行；启用 UFW
cecho "放行 SSH 端口：${SSH_PORT}/tcp"
ufw allow "${SSH_PORT}"/tcp || true

cecho "放行 HY2 监听端口：${LISTEN_PORT}/${PROTO}"
ufw allow "${LISTEN_PORT}/${PROTO}" comment 'HY2 listen' || true

if [[ "$ALLOW_RANGE" == "y" ]]; then
  cecho "放行端口跳跃范围：${RANGE}/${PROTO}"
  ufw allow "${RANGE}/${PROTO}" comment 'HY2 hopping range' || true
fi

wecho "启用 UFW（若已启用会跳过）"
ufw --force enable
systemctl enable ufw >/dev/null 2>&1 || true

# [4/7] 生成 /root/hy2-dnat.sh（强化：按“行号”删光该端口段的所有 DNAT，然后再加）
wecho "[4/7] 生成 /root/hy2-dnat.sh"
cat >/root/hy2-dnat.sh <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
RANGE="${RANGE:-15000:18369}"
TGT_PORT="${TGT_PORT:-2567}"
PROTO="${PROTO:-udp}"

# 删除该端口段上的所有 DNAT（用行号方式，兼容不同目标端口/不同注释）
# 先提取匹配的行号（两次 grep：dpt:RANGE + DNAT）
mapfile -t LNS < <(iptables -t nat -L PREROUTING -n --line-numbers \
  | awk '/DNAT/ && /dpt:'"$RANGE"'/{print $1}')
# 逆序删除（行号会随删除而变化，倒序才稳妥）
for (( idx=${#LNS[@]}-1; idx>=0; idx-- )); do
  ln="${LNS[$idx]}"
  [ -n "$ln" ] && iptables -t nat -D PREROUTING "$ln" || true
done

# 重新加一条带标记的 DNAT
iptables -t nat -A PREROUTING -p "$PROTO" --dport "$RANGE" \
  -m comment --comment "HY2 DNAT autoload" \
  -j DNAT --to-destination ":${TGT_PORT}"

# 打印当前 DNAT 规则以便核对
iptables -t nat -S PREROUTING | grep -E 'DNAT|HY2 DNAT autoload' || true
EOSH
chmod 700 /root/hy2-dnat.sh

# [5/7] 参数文件（以后改这里，即可 systemctl restart hy2-dnat.service）
wecho "[5/7] 写入 /etc/default/hy2-dnat（参数化：范围/目标端口/协议）"
cat >/etc/default/hy2-dnat <<EOF
RANGE="${RANGE}"
TGT_PORT="${LISTEN_PORT}"
PROTO="${PROTO}"
EOF

# [6/7] systemd 服务（确保在 UFW 之后执行）
wecho "[6/7] 生成并启用 hy2-dnat.service"
cat >/etc/systemd/system/hy2-dnat.service <<'EOSVC'
[Unit]
Description=HY2 DNAT rule autoloader (runs after UFW)
After=ufw.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/hy2-dnat
# 如遇极少数竞态，可取消下一行注释增加 5 秒延迟
# ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/env bash -c 'RANGE="${RANGE}" TGT_PORT="${TGT_PORT}" PROTO="${PROTO}" /root/hy2-dnat.sh'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC

systemctl daemon-reload
systemctl enable --now hy2-dnat.service

# [7/7] 验证
cecho "[7/7] 验证：DNAT 规则 / 监听 / 服务状态"
echo "---- DNAT 规则（应看到 PREROUTING DNAT → :${LISTEN_PORT}) ----"
iptables -t nat -S PREROUTING | grep -E "DNAT|:${LISTEN_PORT}" || echo "DNAT 未出现"

echo "---- 监听状态（需 sing-box 已启动，应看到 :${LISTEN_PORT}/${PROTO}) ----"
ss -lunp | grep -E ":${LISTEN_PORT}\b" || echo "${LISTEN_PORT}/${PROTO} 未监听（请确认 sing-box 已启动）"

echo "---- 服务状态（应为 active (exited)） ----"
systemctl status hy2-dnat.service --no-pager || true

cecho "完成 ✅"
wecho "提示：云厂商安全组需放行 ${RANGE}/${PROTO} 入站；客户端启用 server_ports（如 \"15000-18369\"）与 hop_interval。"

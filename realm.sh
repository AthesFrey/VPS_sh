#!/usr/bin/env bash
set -Eeuo pipefail

# ========== 元信息 ==========
# System : CentOS 7+ / Debian 8+ / Ubuntu 16+
# Script : Realm All-in-One Manager
# Version: 1.2-fixed (2025-09-06)

# ========== 颜色 ==========
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
ENDCOLOR="\033[0m"

# ========== 路径 ==========
REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CFG="${REALM_DIR}/config.toml"
REALM_SVC="/etc/systemd/system/realm.service"

# ========== 下载镜像 ==========
ASSET="realm-x86_64-unknown-linux-gnu.tar.gz"
MIRRORS=(
  "https://mirror.ghproxy.com/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  "https://ghproxy.com/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  "https://download.fastgit.org/zhboner/realm/releases/latest/download/${ASSET}"
  "https://gcore.jsdelivr.net/gh/zhboner/realm@latest/${ASSET}"
  "https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
)

# ========== 公用函数 ==========
must_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo -e "${RED}必须以 root 运行${ENDCOLOR}"; exit 1; }; }
installed() { [[ -x "$REALM_BIN" ]]; }
line() { echo "------------------------------------------------------------"; }

fetch_realm() {
  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  for url in "${MIRRORS[@]}"; do
    echo -e "${BLUE}尝试下载：${url}${ENDCOLOR}"
    if curl -fsSL "$url" -o "${tmpdir}/realm.tgz"; then
      if tar -xzf "${tmpdir}/realm.tgz" -C "$tmpdir"; then
        if [[ -f "${tmpdir}/realm" ]]; then
          install -m 0755 "${tmpdir}/realm" "$REALM_BIN"
          echo -e "${GREEN}下载并安装 realm 成功（镜像：${url}）${ENDCOLOR}"
          return 0
        fi
      fi
    fi
    echo -e "${YELLOW}镜像不可用或包结构异常，切换下一个…${ENDCOLOR}"
  done

  echo -e "${RED}全部镜像失败，无法获取 realm。${ENDCOLOR}"
  return 1
}

write_default_config() {
  mkdir -p "$REALM_DIR"
  if [[ ! -s "$REALM_CFG" ]]; then
    cat >"$REALM_CFG" <<'EOF'
# /etc/realm/config.toml
# 参考: https://github.com/zhboner/realm
# 初始为空配置，添加 [[endpoints]] 块后再启动服务。

[log]
level = "info"
EOF
  fi
}

write_service() {
  cat >"$REALM_SVC" <<EOF
[Unit]
Description=Realm relay service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CFG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

safe_enable() { systemctl enable realm >/dev/null 2>&1 || true; }

ipv6_wrap() {
  # 若 remote 是纯 IPv6 且未加 []，则加上。
  local s="$1"
  if [[ "$s" == *:* ]]; then
    # 已含端口的形式 host:port 或 [host]:port，保持端口外层在后续拼接
    # 这里仅返回“主机”部分的规整版
    if [[ "$s" == \[*\] ]]; then
      echo "$s"
    else
      # 只包主机，不含端口
      echo "[$s]"
    fi
  else
    echo "$s"
  fi
}

port_ok() { [[ "$1" =~ ^[0-9]{1,5}$ && "$1" -ge 1 && "$1" -le 65535 ]]; }

rule_exists() {
  local lp="$1"
  [[ -s "$REALM_CFG" ]] && grep -qE "^\s*listen\s*=\s*\"0\.0\.0\.0:${lp}\"" "$REALM_CFG"
}

add_rule() {
  installed || { echo -e "${RED}请先安装 Realm${ENDCOLOR}"; return; }

  echo -e "${YELLOW}请输入转发规则：${ENDCOLOR}"
  read -r -p "本地监听端口: " LPORT
  read -r -p "远程目标地址（域名/IP，IPv6可直接填）: " RADDR
  read -r -p "远程目标端口: " RPORT

  if ! port_ok "$LPORT" || ! port_ok "$RPORT" || [[ -z "${RADDR// }" ]]; then
    echo -e "${RED}输入有误${ENDCOLOR}"; return
  fi
  if rule_exists "$LPORT"; then
    echo -e "${RED}监听端口 ${LPORT} 已存在规则${ENDCOLOR}"; return
  fi

  local HOST_WRAPPED; HOST_WRAPPED="$(ipv6_wrap "$RADDR")"

  {
    echo
    echo '[[endpoints]]'
    echo "listen = \"0.0.0.0:${LPORT}\""
    echo "remote = \"${HOST_WRAPPED}:${RPORT}\""
  } >>"$REALM_CFG"

  echo -e "${GREEN}规则已写入：0.0.0.0:${LPORT} -> ${HOST_WRAPPED}:${RPORT}${ENDCOLOR}"
  systemctl restart realm || true
  echo -e "${GREEN}已尝试重启 realm（若未启用，可在“服务管理”里启用）${ENDCOLOR}"
}

delete_rule() {
  installed || { echo -e "${RED}请先安装 Realm${ENDCOLOR}"; return; }
  if ! grep -q '^\s*\[\[endpoints\]\]' "$REALM_CFG" 2>/dev/null; then
    echo -e "${YELLOW}当前没有可删除的规则${ENDCOLOR}"; return
  fi
  read -r -p "输入要删除的监听端口: " DPORT
  if ! port_ok "$DPORT"; then echo -e "${RED}端口非法${ENDCOLOR}"; return; fi

  # 以空行为记录分隔，删除包含该监听端口的整个 endpoints 块
  awk -v p="$DPORT" '
    BEGIN { RS=""; ORS="\n\n" }
    !($0 ~ /\[\[endpoints\]\]/ && $0 ~ "listen[[:space:]]*=[[:space:]]*\"0\\.0\\.0\\.0:" p "\"")
  ' "$REALM_CFG" | sed '${/^$/d;}' > "${REALM_CFG}.tmp"

  mv "${REALM_CFG}.tmp" "$REALM_CFG"
  systemctl restart realm || true
  echo -e "${GREEN}已删除监听端口 ${DPORT} 的规则并重启 realm${ENDCOLOR}"
}

show_rules() {
  installed || { echo -e "${RED}请先安装 Realm${ENDCOLOR}"; return; }
  echo -e "${BLUE}当前转发规则：${ENDCOLOR}"; line
  if grep -q '^\s*\[\[endpoints\]\]' "$REALM_CFG" 2>/dev/null; then
    awk '
      BEGIN { inblk=0; }
      /^\s*\[\[endpoints\]\]/ { inblk=1; lp=""; rp=""; next; }
      inblk && /^\s*listen\s*=/ { gsub(/[" ]/,""); split($0,a,"="); lp=a[2]; next; }
      inblk && /^\s*remote\s*=/ { gsub(/[" ]/,""); split($0,a,"="); rp=a[2]; printf "  %-24s -> %-24s\n", lp, rp; inblk=0; }
    ' "$REALM_CFG"
  else
    echo -e "${YELLOW}暂无规则${ENDCOLOR}"
  fi
  line
}

install_realm() {
  if installed; then
    echo -e "${GREEN}已检测到 realm（跳过下载）${ENDCOLOR}"
  else
    echo -e "${YELLOW}开始安装 realm ...${ENDCOLOR}"; line
    fetch_realm || exit 1
  fi
  write_default_config
  write_service
  safe_enable
  line
  echo -e "${GREEN}Realm 安装完成。已写入：${ENDCOLOR}"
  echo "  - 二进制: $REALM_BIN"
  echo "  - 配置:   $REALM_CFG"
  echo "  - 服务:   $REALM_SVC（已 daemon-reload，已 enable）"
  echo -e "${YELLOW}提示：首次使用请先添加转发规则，再启动服务。${ENDCOLOR}"
}

service_menu() {
  installed || { echo -e "${RED}请先安装 Realm${ENDCOLOR}"; return; }
  echo "1) 启动  2) 停止  3) 重启  4) 状态  5) 启用开机自启  6) 取消自启"
  read -r -p "选择 [1-6]: " c
  case "$c" in
    1) systemctl start realm ;;
    2) systemctl stop realm ;;
    3) systemctl restart realm ;;
    4) systemctl status realm ;;
    5) systemctl enable realm ;;
    6) systemctl disable realm ;;
    *) echo -e "${RED}无效选项${ENDCOLOR}" ;;
  esac
}

uninstall_realm() {
  installed || { echo -e "${RED}未安装，无需卸载${ENDCOLOR}"; return; }
  read -r -p "确定卸载? (y/N): " yn
  [[ "$yn" =~ ^[yY]$ ]] || { echo -e "${YELLOW}已取消${ENDCOLOR}"; return; }
  systemctl disable --now realm >/dev/null 2>&1 || true
  rm -f "$REALM_BIN" "$REALM_SVC"
  rm -rf "$REALM_DIR"
  systemctl daemon-reload
  echo -e "${GREEN}卸载完成${ENDCOLOR}"
}

# ========== 主菜单 ==========
must_root
while true; do
  clear
  echo -e "${BLUE}Realm 中转一键管理脚本 (v1.2-fixed)${ENDCOLOR}"
  echo "1) 安装 Realm"
  echo "2) 添加转发规则"
  echo "3) 删除转发规则"
  echo "4) 显示已有转发规则"
  echo "5) Realm 服务管理 (启/停/状态/自启)"
  echo "6) 卸载 Realm"
  echo -e "0) ${RED}退出脚本${ENDCOLOR}"
  line
  if installed && systemctl is-active --quiet realm; then
    echo -e "服务状态: ${GREEN}运行中${ENDCOLOR}"
  elif installed; then
    echo -e "服务状态: ${RED}已停止${ENDCOLOR}"
  else
    echo -e "服务状态: ${YELLOW}未安装${ENDCOLOR}"
  fi
  line
  read -r -p "请输入选项 [0-6]: " choice
  case "$choice" in
    1) install_realm ;;
    2) add_rule ;;
    3) delete_rule ;;
    4) show_rules ;;
    5) service_menu ;;
    6) uninstall_realm ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效输入${ENDCOLOR}" ;;
  esac
  echo -e "\n${YELLOW}按 Enter 返回主菜单...${ENDCOLOR}"; read -r
done


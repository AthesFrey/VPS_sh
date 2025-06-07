#!/usr/bin/env bash
#====================================================
#  System  : CentOS 7+ / Debian 8+ / Ubuntu 16+
#  Author  : NET DOWNLOAD (改进 by ChatGPT 2025-06)
#  Script  : Realm All-in-One Manager (带备注增强版)
#  Version : 1.5  (2025-06-07)
#====================================================
set -euo pipefail

# ---------- 颜色 ----------
GREEN="\033[32m"; RED="\033[31m"
YELLOW="\033[33m"; BLUE="\033[34m"; ENDCOLOR="\033[0m"

# ---------- 目录 ----------
REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_DIR="/etc/realm"
REALM_CONFIG_PATH="${REALM_CONFIG_DIR}/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
REALM_LOG_PATH="/var/log/realm-manager.log"

# ---------- 下载镜像 ----------
ASSET="realm-x86_64-unknown-linux-gnu.tar.gz"
MIRRORS=(
  "https://ghfast.top/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  "https://gh-proxy.com/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  "https://cdn.jsdelivr.net/gh/zhboner/realm@latest/${ASSET}"
  "https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
)

# ---------- 权限和平台检查 ----------
[[ $EUID -eq 0 ]] || { echo -e "${RED}必须以 root 运行！${ENDCOLOR}"; exit 1; }
command -v systemctl >/dev/null || { echo -e "${RED}仅支持 systemd 系统！${ENDCOLOR}"; exit 1; }
[[ $(uname -m) == "x86_64" ]] || { echo -e "${RED}仅支持 x86_64 架构，其他架构请手动修改 ASSET。${ENDCOLOR}"; exit 1; }

# ---------- 分隔线 ----------
div() { echo "------------------------------------------------------------"; }

# ---------- 日志记录 ----------
touch "$REALM_LOG_PATH"
logop() { echo "[$(date '+%F %T')] $1" >> "$REALM_LOG_PATH"; }

# ---------- 工具函数 ----------
check_install() { [[ -x $REALM_BIN_PATH ]]; }
valid_port()  { [[ $1 =~ ^[0-9]+$ && $1 -ge 1 && $1 -le 65535 ]]; }

backup_config() {
  [[ -f $REALM_CONFIG_PATH ]] && cp "$REALM_CONFIG_PATH" "/etc/realm.bak.$(date +%s).toml"
}

fetch_realm() {
  local tmpdir
  tmpdir=$(mktemp -d)
  for url in "${MIRRORS[@]}"; do
    echo -e "${BLUE}尝试下载：${url}${ENDCOLOR}"
    if curl -fsSL "$url" | tar -xz -C "$tmpdir"; then
      local bin
      bin=$(find "$tmpdir" -type f -name realm | head -n1)
      if [[ -n "$bin" && ( -x "$bin" || -f "$bin" ) ]]; then
        install -m 755 "$bin" "$REALM_BIN_PATH"
        rm -rf "$tmpdir"
        logop "下载 Realm 成功 $url"
        return 0
      fi
      echo -e "${YELLOW}下载内容无 realm 二进制，切换下一个…${ENDCOLOR}"
    else
      echo -e "${YELLOW}镜像不可用，切换下一个…${ENDCOLOR}"
    fi
  done
  rm -rf "$tmpdir"
  echo -e "${RED}全部镜像尝试失败，无法下载 Realm。${ENDCOLOR}"
  logop "下载 Realm 失败"
  return 1
}

install_realm() {
  if check_install; then
    echo -e "${GREEN}Realm 已安装，无需重复操作。${ENDCOLOR}"
    return
  fi
  echo -e "${YELLOW}开始安装 Realm...${ENDCOLOR}"
  div
  fetch_realm || exit 1

  mkdir -p "$REALM_CONFIG_DIR"
  cat >"$REALM_CONFIG_PATH" <<EOF
[log]
level  = "info"
output = "/var/log/realm.log"
EOF

  cat >"$REALM_SERVICE_PATH" <<EOF
[Unit]
Description=Realm Binary Custom Service
After=network.target

[Service]
Type=simple
User=root
Restart=always
ExecStart=${REALM_BIN_PATH} -c ${REALM_CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1

  div
  echo -e "${GREEN}Realm 安装成功！${ENDCOLOR}"
  echo -e "${YELLOW}已设置开机自启，但尚未启动，请先添加转发规则。${ENDCOLOR}"
  logop "Realm 安装成功"
}

add_rule() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }

  echo -e "${YELLOW}请输入转发规则:${ENDCOLOR}"
  read -rp "本地监听端口: " listen_port
  read -rp "远程目标地址: " remote_addr
  read -rp "远程目标端口: " remote_port
  read -rp "协议 [tcp/udp, 默认tcp]: " proto
  proto=${proto,,}; [[ $proto == udp ]] || proto=tcp
  read -rp "备注（可选，回车跳过）: " note

  valid_port "$listen_port" && valid_port "$remote_port" && [[ -n "$remote_addr" ]] || {
    echo -e "${RED}输入有误！${ENDCOLOR}"; return; }

  ss -lntup | grep -E -q "[:.]${listen_port}\>" && {
    echo -e "${RED}端口 ${listen_port} 已被其他进程占用！${ENDCOLOR}"; return; }

  grep -Fq "listen = \"0.0.0.0:${listen_port}\"" "$REALM_CONFIG_PATH" && {
    echo -e "${RED}该端口已在配置中存在。${ENDCOLOR}"; return; }

  [[ "$remote_addr" == *":"* && "$remote_addr" != \[* ]] && remote_addr="[${remote_addr}]"

  backup_config
  cat >>"$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen   = "0.0.0.0:${listen_port}"
remote   = "${remote_addr}:${remote_port}"
protocol = "${proto}"
note     = "${note}"
EOF

  echo -e "${GREEN}规则添加成功，重启 Realm…${ENDCOLOR}"
  logop "添加规则 ${listen_port} -> ${remote_addr}:${remote_port} [${proto}] 备注:${note}"
  systemctl restart realm && echo -e "${GREEN}已重启。${ENDCOLOR}"
}

delete_rule() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  grep -q "\[\[endpoints\]\]" "$REALM_CONFIG_PATH" || { echo -e "${YELLOW}无规则可删。${ENDCOLOR}"; return; }

  show_rules
  read -rp "输入要删除的监听端口: " del_port
  backup_config
  # 以 [[endpoints]] 为分隔块，准确匹配 listen 字段，整块删除
  awk -v p="$del_port" '
    BEGIN{RS="\\[\\[endpoints\\]\\]"; ORS=""; first=1}
    NF{
      block="[[endpoints]]" $0
      if(block ~ "listen *= *\"0\\.0\\.0\\.0:" p "\"") next
      if(first){print block; first=0} else{print "\n" block}
    }
  ' "$REALM_CONFIG_PATH" > "$REALM_CONFIG_PATH.tmp" && mv "$REALM_CONFIG_PATH.tmp" "$REALM_CONFIG_PATH"

  systemctl restart realm && echo -e "${GREEN}规则删除并重启完毕。${ENDCOLOR}"
  logop "删除规则 $del_port"
}

show_rules() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  echo -e "${BLUE}当前转发规则:${ENDCOLOR}"
  div
  printf "%-8s %-4s %-23s %-23s %-s\n" "端口" "协议" "本地" "目标" "备注"
  div
  if grep -q "\[\[endpoints\]\]" "$REALM_CONFIG_PATH"; then
    awk '
      $1=="listen"   {gsub(/.*:/,"",$3);gsub(/"/,"",$3);port=$3; local="0.0.0.0:"port}
      $1=="remote"   {gsub(/"/,"",$3); remote=$3}
      $1=="protocol" {gsub(/"/,"",$3); proto=$3}
      $1=="note"     {note=substr($0,index($0,"=")+2);gsub(/"/,"",note)}
      /^\[\[endpoints\]\]/ {
        if(port!=""){
          printf "%-8s %-4s %-23s %-23s %s\n", port, proto, local, remote, note
          port=proto=local=remote=note=""
        }
      }
      END {
        if(port!=""){
          printf "%-8s %-4s %-23s %-23s %s\n", port, proto, local, remote, note
        }
      }
    ' "$REALM_CONFIG_PATH"
  else
    echo -e "${YELLOW}暂无规则${ENDCOLOR}"
  fi
  div
}

service_menu() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  echo "1) 启动 2) 停止 3) 重启 4) 状态 5) 自启 6) 取消自启"
  read -rp "选择 [1-6]: " c
  case $c in
    1) systemctl start realm && echo -e "${GREEN}✅ 已启动${ENDCOLOR}" && logop "服务启动" ;;
    2) systemctl stop realm && echo -e "${YELLOW}🛈 已停止${ENDCOLOR}" && logop "服务停止" ;;
    3) systemctl restart realm && echo -e "${GREEN}✅ 已重启${ENDCOLOR}" && logop "服务重启" ;;
    4) systemctl status realm || true ;;
    5) systemctl enable realm && echo -e "${GREEN}✅ 已设置自启${ENDCOLOR}" && logop "设置自启" ;;
    6) systemctl disable realm && echo -e "${YELLOW}🛈 已取消自启${ENDCOLOR}" && logop "取消自启" ;;
    *) echo -e "${RED}无效选项${ENDCOLOR}" ;;
  esac
}

uninstall_realm() {
  check_install || { echo -e "${RED}未安装，无需卸载。${ENDCOLOR}"; return; }
  read -rp "确定卸载? (y/N): " yn
  [[ $yn =~ ^[yY]$ ]] || { echo -e "${YELLOW}已取消${ENDCOLOR}"; return; }
  backup_config
  systemctl stop realm || true
  systemctl disable realm || true
  rm -f "$REALM_BIN_PATH" "$REALM_SERVICE_PATH"
  rm -rf "$REALM_CONFIG_DIR"
  systemctl daemon-reload
  echo -e "${GREEN}卸载完成。配置已备份至 /etc/realm.bak.*.toml${ENDCOLOR}"
  logop "已卸载"
}

show_help() {
  clear
  echo -e "${BLUE}Realm 中转一键管理脚本 (v1.5)${ENDCOLOR}"
  div
  echo -e "支持 CentOS 7+ / Debian 8+ / Ubuntu 16+ (systemd)，自动多镜像安装、TCP/UDP 端口转发、"
  echo -e "支持备注字段，规则可视化、自启管理、配置备份和日志记录。"
  echo -e "配置文件：$REALM_CONFIG_PATH"
  echo -e "日志文件：$REALM_LOG_PATH"
  echo -e "项目主页：https://github.com/zhboner/realm"
  div
  echo -e "${YELLOW}按 Enter 返回主菜单...${ENDCOLOR}"
  read -rn1
}

# ---------- 主菜单 ----------
while true; do
  clear
  echo -e "${BLUE}Realm 中转一键管理脚本 (v1.5)${ENDCOLOR}"
  echo "1. 安装 Realm"
  echo "2. 添加转发规则"
  echo "3. 删除转发规则"
  echo "4. 显示已有转发规则"
  echo "5. Realm 服务管理 (启/停/状态/自启)"
  echo "6. 卸载 Realm"
  echo "7. 帮助/关于"
  echo -e "0. ${RED}退出脚本${ENDCOLOR}"
  div
  if check_install && systemctl is-active --quiet realm; then
    echo -e "服务状态: ${GREEN}运行中${ENDCOLOR}"
  elif check_install; then
    echo -e "服务状态: ${RED}已停止${ENDCOLOR}"
  else
    echo -e "服务状态: ${YELLOW}未安装${ENDCOLOR}"
  fi
  div
  read -rp "请输入选项 [0-7]: " choice
  case $choice in
    1) install_realm ;;
    2) add_rule ;;
    3) delete_rule ;;
    4) show_rules ;;
    5) service_menu ;;
    6) uninstall_realm ;;
    7) show_help ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效输入！${ENDCOLOR}" ;;
  esac
  echo -e "${YELLOW}按 Enter 返回主菜单...${ENDCOLOR}"
  read -rn1
done

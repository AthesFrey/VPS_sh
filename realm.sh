#!/bin/bash
#====================================================
#	System  : CentOS 7+ / Debian 8+ / Ubuntu 16+
#	Author  : NET DOWNLOAD
#	Script  : Realm All-in-One Manager
#	Version : 1.2  (multi-mirror download, 2025-06-04)
#====================================================

# ---------- 颜色 ----------
GREEN="\033[32m"; RED="\033[31m"
YELLOW="\033[33m"; BLUE="\033[34m"; ENDCOLOR="\033[0m"

# ---------- 目录 ----------
REALM_BIN_PATH="/usr/local/bin/realm"
REALM_CONFIG_DIR="/etc/realm"
REALM_CONFIG_PATH="${REALM_CONFIG_DIR}/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"

# ---------- 下载镜像 ----------
ASSET="realm-x86_64-unknown-linux-gnu.tar.gz"
MIRRORS=(
  # 1. mirror.ghproxy  (主推，国内最快、文件完整)
  "https://mirror.ghproxy.com/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  # 2. ghproxy.com      (常用备份)
  "https://ghproxy.com/https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
  # 3. fastgit download
  "https://download.fastgit.org/zhboner/realm/releases/latest/download/${ASSET}"
  # 4. jsdelivr （通过 GH Raw 间接提供，速度一般，对大文件偶尔失效）
  "https://gcore.jsdelivr.net/gh/zhboner/realm@latest/${ASSET}"
  # 5. 官方 GitHub （万一机器能直连）
  "https://github.com/zhboner/realm/releases/latest/download/${ASSET}"
)

# ---------- 权限检查 ----------
[[ $EUID -eq 0 ]] || { echo -e "${RED}必须以 root 运行！${ENDCOLOR}"; exit 1; }

# ---------- 安装检测 ----------
check_install() { [[ -f $REALM_BIN_PATH ]]; }

# ---------- 分隔线 ----------
div() { echo "------------------------------------------------------------"; }

# ---------- 下载函数 ----------
fetch_realm() {
  for url in "${MIRRORS[@]}"; do
    echo -e "${BLUE}尝试下载：${url}${ENDCOLOR}"
    if curl -fsSL "$url" | tar xz; then
      echo -e "${GREEN}下载成功！镜像：${url}${ENDCOLOR}"
      return 0
    else
      echo -e "${YELLOW}镜像不可用，切换下一个…${ENDCOLOR}"
    fi
  done
  echo -e "${RED}全部镜像尝试失败，无法下载 Realm。${ENDCOLOR}"
  return 1
}

# ---------- 安装 ----------
install_realm() {
  if check_install; then
    echo -e "${GREEN}Realm 已安装，无需重复操作。${ENDCOLOR}"
    return
  fi

  echo -e "${YELLOW}开始安装 Realm...${ENDCOLOR}"
  div
  fetch_realm || exit 1

  mv realm "$REALM_BIN_PATH" && chmod +x "$REALM_BIN_PATH"

  mkdir -p "$REALM_CONFIG_DIR"
  cat >"$REALM_CONFIG_PATH" <<EOF
[log]
level = "info"
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
}

# ---------- 添加转发规则 ----------
add_rule() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }

  echo -e "${YELLOW}请输入转发规则:${ENDCOLOR}"
  read -p "本地监听端口: " listen_port
  read -p "远程目标地址: " remote_addr
  read -p "远程目标端口: " remote_port

  [[ $listen_port =~ ^[0-9]+$ && $remote_port =~ ^[0-9]+$ && -n $remote_addr ]] || {
    echo -e "${RED}输入有误！${ENDCOLOR}"; return; }

  grep -q "listen = \"0.0.0.0:${listen_port}\"" "$REALM_CONFIG_PATH" && {
    echo -e "${RED}该端口已存在。${ENDCOLOR}"; return; }

  [[ $remote_addr == *":"* && $remote_addr != \[* ]] && remote_addr="[${remote_addr}]"
  echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${listen_port}\"\nremote = \"${remote_addr}:${remote_port}\"" >>"$REALM_CONFIG_PATH"

  echo -e "${GREEN}规则添加成功，重启 Realm…${ENDCOLOR}"
  systemctl restart realm && echo -e "${GREEN}已重启。${ENDCOLOR}"
}

# ---------- 删除规则 ----------
delete_rule() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  grep -q "\[\[endpoints\]\]" "$REALM_CONFIG_PATH" || { echo -e "${YELLOW}无规则可删。${ENDCOLOR}"; return; }

  show_rules
  read -p "输入要删除的监听端口: " del_port
  awk -v p="$del_port" 'BEGIN{RS="";ORS="\n\n"} !/listen = "0\.0\.0\.0:'"$del_port"'"/' \
      "$REALM_CONFIG_PATH" >"$REALM_CONFIG_PATH.tmp" &&
      mv "$REALM_CONFIG_PATH.tmp" "$REALM_CONFIG_PATH"

  systemctl restart realm && echo -e "${GREEN}规则删除并重启完毕。${ENDCOLOR}"
}

# ---------- 显示规则 ----------
show_rules() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  echo -e "${BLUE}当前转发规则:${ENDCOLOR}"
  div
  if grep -q "\[\[endpoints\]\]" "$REALM_CONFIG_PATH"; then
    grep -E 'listen|remote' "$REALM_CONFIG_PATH" |
      sed 's/listen/本地监听/;s/remote/远程目标/;s/[="]//g' |
      awk '{printf "  %-25s -> %-25s\n", $2, $4}'
  else
    echo -e "${YELLOW}暂无规则${ENDCOLOR}"
  fi
  div
}

# ---------- 服务管理 ----------
service_menu() {
  check_install || { echo -e "${RED}请先安装 Realm。${ENDCOLOR}"; return; }
  echo "1) 启动 2) 停止 3) 重启 4) 状态 5) 自启 6) 取消自启"
  read -p "选择 [1-6]: " c
  case $c in
    1) systemctl start realm ;;
    2) systemctl stop realm ;;
    3) systemctl restart realm ;;
    4) systemctl status realm ;;
    5) systemctl enable realm ;;
    6) systemctl disable realm ;;
    *) echo -e "${RED}无效选项${ENDCOLOR}" ;;
  esac
}

# ---------- 卸载 ----------
uninstall_realm() {
  check_install || { echo -e "${RED}未安装，无需卸载。${ENDCOLOR}"; return; }
  read -p "确定卸载? (y/N): " yn
  [[ $yn == [yY] ]] || { echo -e "${YELLOW}已取消${ENDCOLOR}"; return; }
  systemctl disable --now realm
  rm -f "$REALM_BIN_PATH" "$REALM_SERVICE_PATH"
  rm -rf "$REALM_CONFIG_DIR"
  systemctl daemon-reload
  echo -e "${GREEN}卸载完成。${ENDCOLOR}"
}

# ---------- 主菜单 ----------
while true; do
  clear
  echo -e "${BLUE}Realm 中转一键管理脚本 (v1.2)${ENDCOLOR}"
  echo "1. 安装 Realm"
  echo "2. 添加转发规则"
  echo "3. 删除转发规则"
  echo "4. 显示已有转发规则"
  echo "5. Realm 服务管理 (启/停/状态/自启)"
  echo "6. 卸载 Realm"
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
  read -p "请输入选项 [0-6]: " choice
  case $choice in
    1) install_realm ;;
    2) add_rule ;;
    3) delete_rule ;;
    4) show_rules ;;
    5) service_menu ;;
    6) uninstall_realm ;;
    0) exit 0 ;;
    *) echo -e "${RED}无效输入！${ENDCOLOR}" ;;
  esac
  echo -e "\n${YELLOW}按 Enter 返回主菜单...${ENDCOLOR}"
  read -rn1
done

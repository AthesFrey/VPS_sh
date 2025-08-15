#!/usr/bin/env bash
# ============================================================
# Realm 一键管理脚本（安装 / 配置 / 服务控制 / 升级 / 卸载）
# 适配：Debian / Ubuntu / CentOS / Rocky / Alma / Arch
# 目标：zhboner/realm（Rust 版本，端口转发）
# 作者：Athes（重构稳定版，含备注展示/删除增强）
# 日期：2025-08-15
# 用法：bash realm.sh
# ============================================================

set -o pipefail

# ---------- 配置常量 ----------
REALM_REPO="zhboner/realm"
REALM_BIN="/usr/local/bin/realm"
REALM_CONFIG_DIR="/etc/realm"
REALM_CONFIG_PATH="${REALM_CONFIG_DIR}/config.toml"
REALM_SERVICE_PATH="/etc/systemd/system/realm.service"
REALM_TMP="/tmp/realm_install.$$"
LOG_FILE="/var/log/realm-install.log"

# 颜色
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; ENDC="\033[0m"

# ---------- 实用函数 ----------
log() { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
ok()  { echo -e "${GREEN}$*${ENDC}"; }
warn(){ echo -e "${YELLOW}$*${ENDC}"; }
err() { echo -e "${RED}$*${ENDC}" >&2; }

div(){ echo -e "${BLUE}------------------------------------------------------------${ENDC}"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "需要 root 权限，尝试使用 sudo 重新执行..."
      exec sudo -E bash "$0" "$@"
    else
      err "当前不是 root，且系统未安装 sudo。请切换 root 后重试：sudo -i 或 su -"
      exit 1
    fi
  fi
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return
  elif command -v dnf >/dev/null 2;&1; then echo dnf; return
  elif command -v yum >/dev/null 2>&1; then echo yum; return
  elif command -v pacman >/dev/null 2>&1; then echo pacman; return
  else echo none; return; fi
}

install_pkg() {
  local pm; pm=$(detect_pm)
  case "$pm" in
    apt) apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    none) warn "未探测到包管理器，跳过依赖自动安装：$*"; return 0;;
  esac
}

ensure_deps() {
  local miss=()
  for c in curl tar awk sed grep systemctl; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if ((${#miss[@]})); then
    warn "缺少依赖：${miss[*]}，尝试安装..."
    install_pkg "${miss[@]}" || warn "部分依赖安装失败，请手动确保存在。"
  fi
  # ss/iptables 等非硬依赖
  command -v ss >/dev/null 2>&1 || warn "未检测到 ss（iproute2），端口占用检测将受限。"
}

arch_triplet() {
  local u; u=$(uname -m)
  case "$u" in
    x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    armv7l) echo "armv7-unknown-linux-gnueabihf" ;;
    *) echo "x86_64-unknown-linux-gnu" ; warn "未识别的架构 $u，尝试使用 x86_64 构建（可能失败）。" ;;
  esac
}

fetch_latest_tag() {
  local tag
  tag=$(curl -fsSL "https://api.github.com/repos/${REALM_REPO}/releases/latest" \
        | grep -Eo '"tag_name":\s*"[^"]+"' | awk -F'"' '{print $4}' ) || true
  echo "$tag"
}

download_and_install_realm() {
  mkdir -p "$REALM_TMP"
  local triplet; triplet=$(arch_triplet)
  local tag; tag=$(fetch_latest_tag)

  local candidates=()
  if [[ -n "$tag" ]]; then
    candidates+=(
      "https://github.com/${REALM_REPO}/releases/download/${tag}/realm-${triplet}.tar.gz"
      "https://ghproxy.net/https://github.com/${REALM_REPO}/releases/download/${tag}/realm-${triplet}.tar.gz"
      "https://download.fastgit.org/${REALM_REPO}/releases/download/${tag}/realm-${triplet}.tar.gz"
    )
  fi
  for fallback in v2.5.1 v2.5.0 v2.4.0; do
    candidates+=(
      "https://github.com/${REALM_REPO}/releases/download/${fallback}/realm-${triplet}.tar.gz"
      "https://ghproxy.net/https://github.com/${REALM_REPO}/releases/download/${fallback}/realm-${triplet}.tar.gz"
    )
  done

  local okurl=""
  for u in "${candidates[@]}"; do
    div; echo "尝试下载：$u"
    if curl -fL --connect-timeout 10 --retry 3 --retry-delay 1 -o "${REALM_TMP}/realm.tar.gz" "$u"; then
      okurl="$u"; break
    fi
  done

  if [[ -z "$okurl" ]]; then
    err "下载 Realm 失败：所有镜像均不可用。"
    return 1
  fi

  tar -xzf "${REALM_TMP}/realm.tar.gz" -C "${REALM_TMP}" || { err "解压失败"; return 1; }

  local binpath
  binpath=$(find "${REALM_TMP}" -type f -name realm -perm -u+x | head -n1)
  if [[ -z "$binpath" ]]; then
    err "未在压缩包中找到可执行文件 'realm'。"
    return 1
  fi

  install -m 0755 "$binpath" "$REALM_BIN" || { err "安装二进制失败"; return 1; }
  ok "Realm 安装到 ${REALM_BIN}"
  "$REALM_BIN" -v 2>/dev/null || true
}

backup_config() {
  mkdir -p "$REALM_CONFIG_DIR"
  if [[ -f "$REALM_CONFIG_PATH" ]]; then
    cp -a "$REALM_CONFIG_PATH" "${REALM_CONFIG_PATH}.$(date +%Y%m%d-%H%M%S).bak"
  fi
}

write_default_config_if_missing() {
  mkdir -p "$REALM_CONFIG_DIR"
  if [[ ! -f "$REALM_CONFIG_PATH" ]]; then
    cat >"$REALM_CONFIG_PATH" <<'EOF'
# /etc/realm/config.toml
# 语法：TOML
# 每个 [[endpoints]] 表示一条转发规则
# listen / remote 为 "ip:port"，支持 IPv6（remote 可写为 "[2001:db8::1]:443"）
# protocol: "tcp" 或 "udp"
# note: 可选备注
# 示例：
# [[endpoints]]
# listen = "0.0.0.0:12345"
# remote = "1.2.3.4:12345"
# protocol = "tcp"
# note = "demo"
EOF
  fi
}

write_service_unit() {
  cat >"$REALM_SERVICE_PATH" <<'EOF'
[Unit]
Description=Realm Port Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1 || true
}

check_install() {
  [[ -x "$REALM_BIN" ]]
}

valid_port() {
  local p=$1
  [[ $p =~ ^[0-9]+$ ]] && ((p>0 && p<65536))
}

ensure_installed() {
  check_install && return 0
  err "未检测到 Realm，请先安装。"
  return 1
}

add_rule() {
  ensure_installed || return 1

  echo -ne "本地监听端口: "; read -r listen_port
  echo -ne "远程目标地址 (IP/域名/IPv6): "; read -r remote_addr
  echo -ne "远程目标端口: "; read -r remote_port
  echo -ne "协议 [tcp/udp，默认 tcp]: "; read -r proto
  proto=${proto,,}; [[ "$proto" == "udp" ]] || proto="tcp"
  echo -ne "备注（可选）: "; read -r note

  if ! valid_port "$listen_port" || ! valid_port "$remote_port" || [[ -z "$remote_addr" ]]; then
    err "输入非法。"; return 1
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lntup 2>/dev/null | grep -E -q "[:.]${listen_port}\>"; then
      err "端口 ${listen_port} 已被占用。"; return 1
    fi
  fi

  write_default_config_if_missing

  if grep -Fq "listen = \"0.0.0.0:${listen_port}\"" "$REALM_CONFIG_PATH"; then
    err "配置中已存在该监听端口。"; return 1
  fi

  if [[ "$remote_addr" == *":"* && "$remote_addr" != \[* ]]; then
    remote_addr="[${remote_addr}]"
  fi

  backup_config
  cat >>"$REALM_CONFIG_PATH" <<EOF

[[endpoints]]
listen = "0.0.0.0:${listen_port}"
remote = "${remote_addr}:${remote_port}"
protocol = "${proto}"
note = "$(printf '%s' "$note")"
EOF

  systemctl restart realm
  ok "规则已添加并重启服务：${listen_port} -> ${remote_addr}:${remote_port} (${proto})  备注: ${note}"
}

list_rules() {
  if [[ ! -f "$REALM_CONFIG_PATH" ]]; then
    warn "尚未创建配置文件：$REALM_CONFIG_PATH"
    return 0
  fi
  div
  echo "当前配置：$REALM_CONFIG_PATH"
  awk '
    BEGIN{blk=0;i=0}
    /^\[\[endpoints\]\]/ {blk=1; i++; l=""; r=""; p=""; n=""; next}
    blk && /^listen *=/ {gsub(/"/,""); l=$3}
    blk && /^remote *=/ {gsub(/"/,""); r=$3}
    blk && /^protocol *=/ {gsub(/"/,""); p=$3}
    blk && /^note *=/ {sub(/^note *= */,""); gsub(/"/,""); n=$0}
    blk && /^$/ {printf("  #%d  listen=%-21s  remote=%-30s  proto=%-4s  note=%s\n", i, l, r, p, n); blk=0}
    END{if(blk){printf("  #%d  listen=%-21s  remote=%-30s  proto=%-4s  note=%s\n", i, l, r, p, n)}}
  ' "$REALM_CONFIG_PATH"
  div
}

remove_rule() {
  ensure_installed || return 1
  [[ -f "$REALM_CONFIG_PATH" ]] || { err "找不到配置文件。"; return 1; }

  # 显示现有规则（含备注）
  list_rules

  echo "支持两种方式删除："
  echo "  - 输入端口号（如 12345）按监听端口删除"
  echo "  - 输入序号（如 #2）按列表编号删除"
  echo -ne "请输入要删除的监听端口或序号（回车取消）: "
  read -r key
  [[ -z "$key" ]] && warn "已取消。" && return 0

  local rm_port=""; local rm_index=""
  if [[ "$key" =~ ^#[0-9]+$ ]]; then
    rm_index="${key#\#}"
    if ! [[ "$rm_index" =~ ^[0-9]+$ ]]; then err "序号非法。"; return 1; fi
  elif valid_port "$key"; then
    rm_port="$key"
  else
    err "输入无效。"; return 1
  fi

  backup_config

  # 删除对应 [[endpoints]] 块：支持按端口或序号
  awk -v lp="$rm_port" -v idx="$rm_index" '
    BEGIN{inblk=0; i=0; deleted=0}
    # 记录原始行，便于保持非块段内容
    /^\[\[endpoints\]\]/ {
      if(inblk){print ""}  # 保持块之间空行
      inblk=1; i++; buf=""; matched=0; listen=""
      next
    }
    {
      if(inblk){
        buf = buf $0 ORS
        if($0 ~ /^listen *=/){
          gsub(/"/,"")
          split($3,a,":"); listen=a[2]
        }
        if($0 ~ /^\s*$/){
          # 块结束：决定是否跳过（即删除）
          if( (lp!="" && listen==lp) || (idx!="" && i==idx) ){
            deleted=1
          } else {
            printf("%s", buf)
          }
          inblk=0; buf=""; matched=0; listen=""
        }
        next
      } else {
        printf("%s\n", $0)
      }
    }
    END{
      if(inblk){
        if( (lp!="" && listen==lp) || (idx!="" && i==idx) ){
          deleted=1
        } else {
          printf("%s", buf)
        }
      }
      if(!deleted){
        if(lp!=""){
          printf("%s", "") > "/dev/stderr"
        }else if(idx!=""){
          printf("%s", "") > "/dev/stderr"
        }
      }
    }
  ' "$REALM_CONFIG_PATH" > "${REALM_CONFIG_PATH}.tmp"

  if cmp -s "$REALM_CONFIG_PATH" "${REALM_CONFIG_PATH}.tmp"; then
    rm -f "${REALM_CONFIG_PATH}.tmp"
    if [[ -n "$rm_port" ]]; then
      err "未找到监听端口 ${rm_port} 的规则。"
    else
      err "未找到序号 #${rm_index} 的规则。"
    fi
    return 1
  fi

  mv "${REALM_CONFIG_PATH}.tmp" "$REALM_CONFIG_PATH"
  systemctl restart realm
  if [[ -n "$rm_port" ]]; then
    ok "已删除端口 ${rm_port} 的规则并重启服务。"
  else
    ok "已删除序号 #${rm_index} 的规则并重启服务。"
  fi
}

start_srv()   { ensure_installed || return 1; systemctl start realm && ok "已启动 realm"; }
stop_srv()    { systemctl stop realm && ok "已停止 realm"; }
restart_srv() { ensure_installed || return 1; systemctl restart realm && ok "已重启 realm"; }
status_srv()  { systemctl status realm --no-pager; }

install_realm() {
  if check_install; then
    ok "Realm 已安装：$REALM_BIN"
  else
    div; warn "开始安装 Realm ..."
    download_and_install_realm || { err "安装失败"; return 1; }
  fi
  write_default_config_if_missing
  write_service_unit
  div; ok "安装流程完成。"
  warn "已设置开机自启，但未自动启动。请先添加转发规则后再启动。"
}

upgrade_realm() {
  ensure_installed || return 1
  local vsn_before; vsn_before=$("$REALM_BIN" -v 2>/dev/null | head -n1 || true)
  warn "当前版本：${vsn_before}"
  download_and_install_realm || { err "下载/安装新版本失败"; return 1; }
  systemctl restart realm || true
  ok "升级完成。新版本：$("$REALM_BIN" -v 2>/dev/null | head -n1 || echo unknown)"
}

uninstall_realm() {
  warn "将卸载 Realm（保留配置文件）。继续？[y/N]"
  read -r ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    warn "已取消。"; return 0
  fi
  systemctl disable --now realm >/dev/null 2>&1 || true
  rm -f "$REALM_BIN"
  rm -f "$REALM_SERVICE_PATH"
  systemctl daemon-reload
  ok "已卸载 Realm（保留配置：$REALM_CONFIG_PATH）"
}

menu() {
  clear
  echo -e "${GREEN}Realm 一键管理脚本${ENDC}  （仓库：${REALM_REPO}）"
  div
  echo " 1) 安装 / 修复安装"
  echo " 2) 添加转发规则"
  echo " 3) 删除转发规则（按端口或 #序号）"
  echo " 4) 查看当前规则（含备注）"
  echo " 5) 启动服务"
  echo " 6) 停止服务"
  echo " 7) 重启服务"
  echo " 8) 查看服务状态"
  echo " 9) 升级 Realm"
  echo "10) 卸载 Realm（保留配置）"
  echo "11) 退出"
  div
  echo -ne "请选择 [1-11]: "
}

main() {
  need_root "$@"
  ensure_deps
  touch "$LOG_FILE" 2>/dev/null || true

  while true; do
    menu
    read -r choice
    case "$choice" in
      1) install_realm ;;
      2) add_rule ;;
      3) remove_rule ;;
      4) list_rules ;;
      5) start_srv ;;
      6) stop_srv ;;
      7) restart_srv ;;
      8) status_srv ;;
      9) upgrade_realm ;;
      10) uninstall_realm ;;
      11) exit 0 ;;
      *) warn "无效选项";;
    esac
    echo; read -rp "按回车继续..." _
  done
}

trap 'err "发生错误：行号 $LINENO。请查看日志 $LOG_FILE"; exit 1' ERR
main "$@"




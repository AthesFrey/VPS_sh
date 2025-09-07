#!/usr/bin/env bash
# realm 安装/升级/卸载 管理脚本（修正版0907）
# - 修复 write_service() 空实现 / safe_enable 未定义
# - 支持再次运行进行“就地覆盖升级”，可选择是否覆盖配置
# - 幂等可重复运行，带备份与回滚

set -Eeuo pipefail

# ========== 全局变量 ==========
APP_NAME="realm"
BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
TMP_DIR=""
TS="$(date +%F-%H%M%S)"

# 下载来源（依次尝试，避免单点）
ASSET_X86="realm-x86_64-unknown-linux-gnu.tar.gz"
ASSET_ARM="realm-aarch64-unknown-linux-gnu.tar.gz"
GITHUB_DL="https://github.com/zhboner/realm/releases/latest/download"
MIRRORS=(
  "$GITHUB_DL"                          # 官方
  "https://ghfast.top/$GITHUB_DL"       # 加速镜像1
  "https://download.fastgit.org/zhboner/realm/releases/latest/download"  # 加速镜像2
)

# ========== 工具函数 ==========
log() { printf "\033[1;32m[i]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }

require_root(){
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 运行（sudo -i 后执行）。"
    exit 1
  fi
}

cleanup(){
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}" || true
  fi
}
trap cleanup EXIT

detect_arch_asset(){
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "$ASSET_X86" ;;
    aarch64|arm64) echo "$ASSET_ARM" ;;
    *)
      err "暂不支持架构：$arch"
      exit 2
      ;;
  esac
}

ensure_cmds(){
  local need=(curl tar install)
  local miss=()
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || miss+=("$c")
  done
  if ((${#miss[@]})); then
    warn "缺少依赖：${miss[*]}，尝试自动安装"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y curl tar coreutils || {
        err "自动安装失败，请手动安装：${miss[*]}"
        exit 3
      }
    else
      err "当前发行版不支持自动装依赖，请手动安装：${miss[*]}"
      exit 3
    fi
  fi
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.${TS}"
  log "已备份：$f -> ${f}.bak.${TS}"
}

current_version(){
  # 尽量兼容不同版本输出方式
  if [[ -x "$BIN_PATH" ]]; then
    (
      set +e
      "$BIN_PATH" -v 2>/dev/null && exit 0
      "$BIN_PATH" -V 2>/dev/null && exit 0
      "$BIN_PATH" version 2>/dev/null && exit 0
      # 兜底：打印文件hash
      sha256sum "$BIN_PATH" 2>/dev/null | awk '{print "sha256:"$1}'
    )
  else
    echo "(未安装)"
  fi
}

dl_asset(){
  local asset="$1"
  TMP_DIR="$(mktemp -d)"
  local out="${TMP_DIR}/realm.tgz"
  local ok=0
  for base in "${MIRRORS[@]}"; do
    local url="${base}/${asset}"
    log "尝试下载：$url"
    if curl -fL --connect-timeout 10 --retry 2 -o "$out" "$url"; then
      ok=1; break
    else
      warn "下载失败：$url"
    fi
  done
  if [[ $ok -ne 1 ]]; then
    err "所有镜像下载失败，请检查网络后重试。"
    exit 4
  fi
  echo "$out"
}

extract_and_stage(){
  local tgz="$1"
  tar -xzf "$tgz" -C "$TMP_DIR"
  [[ -f "${TMP_DIR}/realm" ]] || { err "压缩包内未发现 realm 可执行文件"; exit 5; }
  echo "${TMP_DIR}/realm"
}

write_default_config(){
  mkdir -p "$CONF_DIR"
  if [[ ! -s "$CONF_FILE" ]]; then
    cat >"$CONF_FILE" <<'EOF'
# /etc/realm/config.toml 示例（请按需修改）
# 文档参考：https://github.com/zhboner/realm
# 典型入站/出站中继配置：
# [[endpoints]]
# listen = "0.0.0.0:443"
# remote = "127.0.0.1:8443"
# # sniff = "http tls"
# # http=false
# # tls=false

EOF
    log "已生成默认配置：$CONF_FILE（当前为空模板，后续请自行填充）"
  else
    log "保留现有配置：$CONF_FILE"
  fi
}

write_service(){
  # 幂等：若存在且无变化则不改；若存在且不同则备份后覆盖
  local unit_content
  read -r -d '' unit_content <<EOF || true
[Unit]
Description=Realm relay
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${BIN_PATH} -c ${CONF_FILE} -d
Restart=always
RestartSec=3
WorkingDirectory=/root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$(dirname "$SERVICE_FILE")"
  if [[ -f "$SERVICE_FILE" ]]; then
    if ! diff -q <(echo "$unit_content") "$SERVICE_FILE" >/dev/null 2>&1; then
      backup_file "$SERVICE_FILE"
      printf "%s" "$unit_content" > "$SERVICE_FILE"
      log "已更新 systemd 单元：$SERVICE_FILE"
    else
      log "systemd 单元无变化：$SERVICE_FILE"
    fi
  else
    printf "%s" "$unit_content" > "$SERVICE_FILE"
    log "已写入 systemd 单元：$SERVICE_FILE"
  fi
}

daemon_reload(){ systemctl daemon-reload || true; }

safe_enable(){
  # 幂等：enable/启动失败不致命，但会提示
  daemon_reload
  if systemctl is-enabled --quiet "${APP_NAME}" 2>/dev/null; then
    log "服务已 enable：${APP_NAME}.service"
  else
    if systemctl enable "${APP_NAME}" 2>/dev/null; then
      log "已 enable：${APP_NAME}.service"
    else
      warn "enable 失败，请手动执行：systemctl enable ${APP_NAME}"
    fi
  fi

  if systemctl is-active --quiet "${APP_NAME}" 2>/dev/null; then
    if systemctl restart "${APP_NAME}" 2>/dev/null; then
      log "已重启：${APP_NAME}.service"
    else
      warn "restart 失败，请检查日志：journalctl -u ${APP_NAME} -e"
    fi
  else
    if systemctl start "${APP_NAME}" 2>/dev/null; then
      log "已启动：${APP_NAME}.service"
    else
      warn "start 失败，请检查日志：journalctl -u ${APP_NAME} -e"
    fi
  fi
}

install_binary(){
  local staged="$1"
  mkdir -p "$BIN_DIR"
  if [[ -x "$BIN_PATH" ]]; then
    backup_file "$BIN_PATH"
  fi
  install -m 0755 "$staged" "$BIN_PATH"
  log "已安装二进制：$BIN_PATH"
}

install_fresh(){
  # 全新安装（不删已有配置，仅生成默认配置）
  local asset tgz staged
  asset="$(detect_arch_asset)"
  tgz="$(dl_asset "$asset")"
  staged="$(extract_and_stage "$tgz")"

  write_default_config
  install_binary "$staged"
  write_service
  safe_enable

  log "安装完成。当前版本：$(current_version)"
}

upgrade_inplace(){
  # 升级二进制，是否覆盖配置由参数决定
  local overwrite_conf="${1:-no}"  # yes/no
  local asset tgz staged

  if [[ ! -x "$BIN_PATH" ]]; then
    warn "检测到未安装 ${APP_NAME}，将执行全新安装。"
    install_fresh
    return
  fi

  log "当前已安装版本：$(current_version)"
  systemctl stop "${APP_NAME}" 2>/dev/null || true

  asset="$(detect_arch_asset)"
  tgz="$(dl_asset "$asset")"
  staged="$(extract_and_stage "$tgz")"

  # 配置处理
  mkdir -p "$CONF_DIR"
  if [[ "$overwrite_conf" == "yes" ]]; then
    backup_file "$CONF_FILE"
    cat >"$CONF_FILE" <<'EOF'
# /etc/realm/config.toml （已重置为模板，请按需修改）
# [[endpoints]]
# listen = "0.0.0.0:443"
# remote = "127.0.0.1:8443"
EOF
    log "已覆盖配置：$CONF_FILE（模板）"
  else
    write_default_config  # 仅在缺省时生成，不会覆盖
  fi

  install_binary "$staged"
  write_service
  safe_enable

  log "升级完成。当前版本：$(current_version)"
}

uninstall_keep_or_purge(){
  # 选择保留配置或彻底清理
  echo
  echo "请选择卸载方式："
  echo "  1) 卸载程序（保留 /etc/realm 配置）"
  echo "  2) 卸载程序（并删除 /etc/realm 配置）"
  read -rp "[1/2, 默认1]: " choice
  choice="${choice:-1}"

  systemctl stop "${APP_NAME}" 2>/dev/null || true
  systemctl disable "${APP_NAME}" 2>/dev/null || true

  if [[ -x "$BIN_PATH" ]]; then
    backup_file "$BIN_PATH"
    rm -f "$BIN_PATH"
    log "已移除二进制：$BIN_PATH"
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    backup_file "$SERVICE_FILE"
    rm -f "$SERVICE_FILE"
    log "已移除 systemd 单元：$SERVICE_FILE"
    daemon_reload
  fi

  if [[ "$choice" == "2" ]]; then
    if [[ -d "$CONF_DIR" ]]; then
      backup_file "$CONF_DIR"
      rm -rf "$CONF_DIR"
      log "已删除配置目录：$CONF_DIR（备份已留存）"
    fi
  else
    log "保留配置目录：$CONF_DIR"
  fi

  log "卸载完成。"
}

show_status(){
  echo "二进制路径：$BIN_PATH"
  echo "版本：$(current_version)"
  echo "配置：$CONF_FILE $( [[ -s "$CONF_FILE" ]] && echo '(存在)' || echo '(缺失或空)' )"
  echo "服务：$SERVICE_FILE $( systemctl is-active --quiet "${APP_NAME}" && echo '(active)' || echo '(inactive)' )"
}

main_menu(){
  echo
  echo "==== ${APP_NAME} 管理 ===="
  echo "1) 全新安装 / 首次安装"
  echo "2) 升级（仅覆盖二进制，保留配置）【推荐】"
  echo "3) 升级（覆盖二进制 + 覆盖配置为模板）"
  echo "4) 卸载（可选是否保留配置）"
  echo "5) 查看状态"
  echo "q) 退出"
  read -rp "请选择: " op
  case "$op" in
    1) install_fresh ;;
    2) upgrade_inplace "no" ;;
    3) upgrade_inplace "yes" ;;
    4) uninstall_keep_or_purge ;;
    5) show_status ;;
    q|Q) exit 0 ;;
    *) warn "无效选择";;
  esac
}

# ========== 入口 ==========
require_root
ensure_cmds
main_menu

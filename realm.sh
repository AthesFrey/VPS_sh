#!/usr/bin/env bash
# realm 安装/升级/卸载/节点管理 脚本（稳定版 v3.9）
# 变更（相对 v3.8）：
# - 解析器修复：当处于上一块 [[endpoints]] 内时，遇到下一块的 "# remark:" 会先结束上一块（end=remark前一行），防止误删下一块备注
# - 继续使用 AWK 区间过滤删除；主菜单循环；无 eid；remark 缺失显示为 null-remark；添加节点可连续添加；端口直输=0.0.0.0:PORT
# ======================================================

set -Eeuo pipefail

APP_NAME="realm"
BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
LOG_FILE="/var/log/realm.log"

TS="$(date +%F-%H%M%S)"
TMP_DIR=""
TGZ_PATH=""
STAGED_BIN=""

ASSET_X86="realm-x86_64-unknown-linux-gnu.tar.gz"
ASSET_ARM="realm-aarch64-unknown-linux-gnu.tar.gz"

MIRRORS=(
  "https://ghfast.top/https://github.com/zhboner/realm/releases/latest/download"
  "https://gh-proxy.com/https://github.com/zhboner/realm/releases/latest/download"
  "https://download.fastgit.org/zhboner/realm/releases/latest/download"
  "https://github.com/zhboner/realm/releases/latest/download"
)

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-8}"
REALM_MAXTIME="${REALM_MAXTIME:-45}"
REALM_SPEED_LIMIT="${REALM_SPEED_LIMIT:-16384}"
REALM_SPEED_TIME="${REALM_SPEED_TIME:-15}"
CURL_FORCE_IPv4_OPTS=""
if [[ "${REALM_FORCE_IPV4:-0}" == "1" ]]; then
  CURL_FORCE_IPv4_OPTS="-4"
fi
CURL_OPTS=(-fL --retry 1 --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${REALM_MAXTIME}" --speed-limit "${REALM_SPEED_LIMIT}" --speed-time "${REALM_SPEED_TIME}")
if [[ -n "${CURL_FORCE_IPv4_OPTS}" ]]; then
  CURL_OPTS+=("${CURL_FORCE_IPv4_OPTS}")
fi

log()  { command printf "\033[1;32m[i]\033[0m %s\n" "$*" >&2; }
warn() { command printf "\033[1;33m[!]\033[0m %s\n" "$*" >&2; }
err()  { command printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }

require_root(){ [[ $EUID -eq 0 ]] || { err "请以 root 运行（sudo -i 后执行）。"; exit 1; }; }

cleanup(){
  [[ -n "${TMP_DIR}"  && -d "${TMP_DIR}"  ]] && rm -rf "${TMP_DIR}"  || true
  [[ -n "${TGZ_PATH}" && -f "${TGZ_PATH}" ]] && rm -f  "${TGZ_PATH}" || true
}
trap cleanup EXIT

ensure_cmds(){
  local need=(curl tar install file gzip awk sed grep nc ss systemctl)
  local miss=()
  for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if ((${#miss[@]})); then
    warn "缺少依赖：${miss[*]}，尝试自动安装"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y && apt-get install -y curl tar coreutils file gzip gawk sed grep netcat-openbsd iproute2 systemd || { err "依赖安装失败"; exit 3; }
    else
      err "非 Debian/Ubuntu 系需手动安装：${miss[*]}"; exit 3
    fi
  fi
}

backup_file(){ local f="$1"; [[ -e "$f" ]] || return 0; cp -a "$f" "${f}.bak.${TS}"; log "已备份：$f -> ${f}.bak.${TS}"; }

current_version(){
  if [[ -x "$BIN_PATH" ]]; then
    ( set +e
      "$BIN_PATH" -v 2>/dev/null && exit 0
      "$BIN_PATH" -V 2>/dev/null && exit 0
      "$BIN_PATH" version 2>/dev/null && exit 0
      sha256sum "$BIN_PATH" 2>/dev/null | awk '{print "sha256:"$1}'
    )
  else
    echo "(未安装)"
  fi
}

detect_asset(){
  case "$(uname -m)" in
    x86_64|amd64) echo "$ASSET_X86" ;;
    aarch64|arm64) echo "$ASSET_ARM" ;;
    *) err "暂不支持架构：$(uname -m)"; exit 2 ;;
  esac
}

prepare_paths(){
  TMP_DIR="$(mktemp -d)"
  TGZ_PATH="${TMP_DIR}/realm.tgz"
  STAGED_BIN="${TMP_DIR}/realm"
}

download_and_verify(){ # 0 成功 / 1 失败
  local asset="$1"
  : > "${TGZ_PATH}"
  local ok=0
  for base in "${MIRRORS[@]}"; do
    local url="${base}/${asset}"
    log "尝试下载：${url}"
    rm -f "${TGZ_PATH}" || true
    if curl "${CURL_OPTS[@]}" -o "${TGZ_PATH}" "${url}"; then
      if [[ ! -s "${TGZ_PATH}" ]]; then warn "下载到空文件，切下一个镜像……"; continue; fi
      if ! file -b "${TGZ_PATH}" | grep -iq 'gzip'; then warn "文件类型异常（非 gzip），切下一个镜像……"; continue; fi
      if ! gzip -t "${TGZ_PATH}" >/dev/null 2>&1; then warn "gzip 校验失败，切下一个镜像……"; continue; fi
      if ! tar -tzf "${TGZ_PATH}" >/dev/null 2>&1; then warn "tar 目录校验失败，切下一个镜像……"; continue; fi
      ok=1; break
    else
      warn "下载失败：${url}"
    fi
  done
  if [[ $ok -ne 1 ]]; then err "所有镜像下载/校验均失败。"; return 1; fi
  return 0
}

extract_stage(){ # 0 成功 / 1 失败
  if ! tar -xzf "${TGZ_PATH}" -C "${TMP_DIR}"; then err "解包失败：${TGZ_PATH}"; return 1; fi
  if [[ ! -f "${STAGED_BIN}" ]]; then err "压缩包内未发现 realm 可执行文件"; return 1; fi
  chmod +x "${STAGED_BIN}" || true
  return 0
}

write_default_config(){
  mkdir -p "$CONF_DIR"
  if [[ ! -s "$CONF_FILE" ]]; then
    cat >"$CONF_FILE" <<'EOF'
# /etc/realm/config.toml（示例模板，请按需修改）
# [[endpoints]]
# listen = "0.0.0.0:3568"
# remote = "127.0.0.1:8080"
# sniff  = "http tls"
# http   = false
# tls    = false
EOF
    log "已生成默认配置：$CONF_FILE（模板）"
  else
    log "保留现有配置：$CONF_FILE"
  fi
}

write_service(){
  local unit_content
  read -r -d '' unit_content <<EOF || true
[Unit]
Description=Realm relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${CONF_FILE}
Restart=always
RestartSec=3
WorkingDirectory=/root
LimitNOFILE=1048576
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p "$(dirname "$SERVICE_FILE")"
  if [[ -f "$SERVICE_FILE" ]]; then
    if ! diff -q <(echo "$unit_content") "$SERVICE_FILE" >/dev/null 2>&1; then
      backup_file "$SERVICE_FILE"
      command printf "%s" "$unit_content" > "$SERVICE_FILE"
      log "已更新 systemd 单元：$SERVICE_FILE"
    else
      log "systemd 单元无变化：$SERVICE_FILE"
    fi
  else
    command printf "%s" "$unit_content" > "$SERVICE_FILE"
    log "已写入 systemd 单元：$SERVICE_FILE"
  fi
}

daemon_reload(){ systemctl daemon-reload || true; }

safe_enable(){
  pkill -x "${APP_NAME}" 2>/dev/null || true
  daemon_reload
  systemctl enable "${APP_NAME}" 2>/dev/null || warn "enable 失败，可手动：systemctl enable ${APP_NAME}"
  if systemctl is-active --quiet "${APP_NAME}" 2>/dev/null; then
    systemctl restart "${APP_NAME}" 2>/dev/null || warn "restart 失败：journalctl -u ${APP_NAME} -e"
  else
    systemctl start "${APP_NAME}" 2>/dev/null || warn "start 失败：journalctl -u ${APP_NAME} -e"
  fi
}

install_binary(){
  mkdir -p "$BIN_DIR"
  [[ -x "$BIN_PATH" ]] && backup_file "$BIN_PATH"
  install -m 0755 "${STAGED_BIN}" "$BIN_PATH"
  log "已安装二进制：$BIN_PATH"
}

install_fresh(){
  local asset; asset="$(detect_asset)"
  prepare_paths
  download_and_verify "$asset" || exit 4
  extract_stage || exit 5
  write_default_config
  install_binary
  write_service
  safe_enable
  log "安装完成。当前版本：$(current_version)"
}

upgrade_inplace(){
  local overwrite_conf="${1:-no}"  # yes/no
  if [[ ! -x "$BIN_PATH" ]]; then
    warn "检测到未安装 ${APP_NAME}，将执行全新安装。"
    install_fresh; return
  fi
  log "当前已安装版本：$(current_version)"
  systemctl stop "${APP_NAME}" 2>/dev/null || true

  local asset; asset="$(detect_asset)"
  prepare_paths
  download_and_verify "$asset" || exit 4
  extract_stage || exit 5

  mkdir -p "$CONF_DIR"
  if [[ "$overwrite_conf" == "yes" ]]; then
    backup_file "$CONF_FILE"
    cat >"$CONF_FILE" <<'EOF'
# /etc/realm/config.toml （已重置为模板）
# [[endpoints]]
# listen = "0.0.0.0:3568"
# remote = "127.0.0.1:8080"
# sniff  = "http tls"
# http   = false
# tls    = false
EOF
    log "已覆盖配置：$CONF_FILE（模板）"
  else
    write_default_config
  fi

  install_binary
  write_service
  safe_enable
  log "升级完成。当前版本：$(current_version)"
}

uninstall_keep_or_purge(){
  local purge="${1:-no}"  # yes/no
  systemctl stop "${APP_NAME}" 2>/dev/null || true
  systemctl disable "${APP_NAME}" 2>/dev/null || true

  [[ -x "$BIN_PATH" ]] && { backup_file "$BIN_PATH"; rm -f "$BIN_PATH"; log "已移除二进制：$BIN_PATH"; }

  if [[ -f "$SERVICE_FILE" ]]; then
    backup_file "$SERVICE_FILE"; rm -f "$SERVICE_FILE"; log "已移除 systemd 单元：$SERVICE_FILE"; daemon_reload
  fi

  if [[ "$purge" == "yes" ]]; then
    [[ -d "$CONF_DIR" ]] && { backup_file "$CONF_DIR"; rm -rf "$CONF_DIR"; log "已删除配置目录：$CONF_DIR（备份已留存）"; }
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

# =================== 节点管理 ===================

ensure_config(){
  mkdir -p "$CONF_DIR"
  [[ -f "$CONF_FILE" ]] || write_default_config
}

# 解析并列出所有 [[endpoints]] 块，输出：idx|start|end|remark|listen|remote
parse_endpoints(){
  ensure_config
  awk '
    BEGIN{
      idx=0; inblk=0; start=0
      remark=""; listen=""; remote=""
      pend_remark=""; pend_remark_line=0
    }
    function Trim(s){ sub(/^[ \t\r\n]+/,"",s); sub(/[ \t\r\n]+$/,"",s); return s }
    function flush_block(endline){
      if(inblk){
        idx++
        printf("%d|%d|%d|%s|%s|%s\n", idx, start, endline, remark, listen, remote)
      }
      inblk=0; start=0; remark=""; listen=""; remote=""
    }
    {
      line=$0

      if (inblk) {
        # 若在块内遇到下一块的备注，先结束当前块（不吞掉该备注行）
        if (match(line, /^[ \t]*#\s*remark:[ \t]*(.*)$/, m)){
          flush_block(NR-1)
          inblk=0
          pend_remark = Trim(m[1]); pend_remark_line=NR
          next
        }
        # 监听/后端
        if (match(line, /^[ \t]*listen[ \t]*=[ \t]*"(.*)"/, m)) { listen = Trim(m[1]); next }
        if (match(line, /^[ \t]*remote[ \t]*=[ \t]*"(.*)"/, m)) { remote = Trim(m[1]); next }
        # 新块开始
        if (match(line, /^[ \t]*\[\[endpoints\]\][ \t]*$/)) {
          flush_block(NR-1)
          inblk=1
          if (pend_remark_line==NR-1) { start=pend_remark_line } else { start=NR }
          remark=pend_remark
          listen=""; remote=""
          pend_remark=""; pend_remark_line=0
          next
        }
        next
      }

      # 非块内逻辑
      if (match(line, /^[ \t]*#\s*remark:[ \t]*(.*)$/, m)){
        pend_remark = Trim(m[1]); pend_remark_line=NR; next
      }

      if (match(line, /^[ \t]*\[\[endpoints\]\][ \t]*$/)) {
        inblk=1
        if (pend_remark_line==NR-1) { start=pend_remark_line } else { start=NR }
        remark=pend_remark
        listen=""; remote=""
        pend_remark=""; pend_remark_line=0
        next
      }

      if (line !~ /^[ \t]*#/) { pend_remark=""; pend_remark_line=0 }
    }
    END{
      if (inblk) flush_block(NR)
    }
  ' "$CONF_FILE"
}

list_endpoints(){
  local rows
  rows="$(parse_endpoints || true)"
  if [[ -z "$rows" ]]; then
    echo "（暂无 [[endpoints]] 节点）"
    return 0
  fi
  command printf '%s\n' "Idx  Listen                      -> Remote                     | Remark"
  command printf '%s\n' "---- ---------------------------- ---------------------------- | -----------------------------"
  while IFS='|' read -r idx start end remark listen remote; do
    [[ -z "$remark" ]] && remark="null-remark"
    command printf '%-4s %-28s -> %-28s | %s\n' "${idx}" "${listen:-"-"}" "${remote:-"-"}" "${remark}"
  done <<<"$rows"
}

# 支持 ipv4/域名:port 或 [ipv6]:port
validate_hostport(){
  local hp="$1"
  hp="${hp#"${hp%%[![:space:]]*}"}"; hp="${hp%"${hp##*[![:space:]]}"}"
  if [[ "$hp" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
    local port="${BASH_REMATCH[1]}"
    ((port>=1 && port<=65535)) || return 1
    return 0
  fi
  if [[ "$hp" =~ ^[^:[:space:]]+:([0-9]{1,5})$ ]]; then
    local port="${BASH_REMATCH[1]}"
    ((port>=1 && port<=65535)) || return 1
    return 0
  fi
  return 1
}

# 仅端口（数字）转为 0.0.0.0:PORT
normalize_listen(){
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^[0-9]{1,5}$ ]]; then
    echo "0.0.0.0:$v"
    return 0
  fi
  echo "$v"
}

_trim(){ local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; command printf '%s' "$s"; }

add_endpoint_interactive(){
  ensure_config
  while true; do
    local listen remote remark sniff http tls

    while true; do
      read -rp "监听端口/地址（直接输入端口如 3569，等价 0.0.0.0:3569；或输入完整 host:port）: " listen
      listen="$(normalize_listen "$(_trim "$listen")")"
      validate_hostport "$listen" && break || echo "格式不正确：请仅输入端口（如 3569）或完整的 host:port（IPv6 用 [::1]:443）"
    done

    while true; do
      read -rp "后端地址 remote (如 127.0.0.1:8080 或 [::1]:8080): " remote
      remote="$(_trim "$remote")"
      validate_hostport "$remote" && break || echo "格式不正确：请输入 host:port（IPv6 用 [::1]:443）"
    done

    read -rp "sniff（默认 \"http tls\"，回车使用默认）: " sniff
    sniff="$(_trim "${sniff:-http tls}")"
    read -rp "http 开关（true/false，默认 false）: " http; http="$(_trim "${http:-false}")"
    read -rp "tls  开关（true/false，默认 false）: " tls;  tls="$(_trim "${tls:-false}")"
    read -rp "备注 remark（可留空）: " remark
    remark="$(_trim "$remark")"

    backup_file "$CONF_FILE"

    {
      echo ""
      echo "# remark: $remark"
      echo "[[endpoints]]"
      echo "listen = \"${listen}\""
      echo "remote = \"${remote}\""
      echo "sniff  = \"${sniff}\""
      echo "http   = ${http}"
      echo "tls    = ${tls}"
    } >> "$CONF_FILE"

    log "已追加节点：$listen -> $remote  （remark: ${remark:-null-remark})"
    systemctl restart "${APP_NAME}" 2>/dev/null || warn "重启服务失败，查看：journalctl -u ${APP_NAME} -e"

    read -rp "需要继续添加下一个节点吗？(y/N): " yn
    yn="${yn:-N}"; yn="${yn,,}"
    if [[ "$yn" != "y" && "$yn" != "yes" ]]; then
      break
    fi
  done
}

delete_endpoints_interactive(){
  ensure_config
  local rows; rows="$(parse_endpoints || true)"
  if [[ -z "$rows" ]]; then echo "当前没有可删除的节点。"; return 0; fi
  list_endpoints
  echo
  read -rp "输入要删除的索引（支持逗号和区间，如 1,3,5-7）: " sel
  [[ -n "$sel" ]] || { echo "未输入。"; return 1; }

  declare -A mark=()
  IFS=',' read -ra parts <<<"$sel"
  for p in "${parts[@]}"; do
    p="${p//[[:space:]]/}"
    if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
      local a b t i
      a="${p%-*}"; b="${p#*-}"
      if (( a > b )); then t="$a"; a="$b"; b="$t"; fi
      for ((i=a; i<=b; i++)); do mark["$i"]=1; done
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      mark["$p"]=1
    fi
  done

  local starts=() ends=()
  while IFS='|' read -r idx start end remark listen remote; do
    if [[ -n "${mark[$idx]:-}" ]]; then
      [[ -z "$remark" ]] && remark="null-remark"
      command printf '将删除 #%s: %s -> %s | %s\n' "$idx" "$listen" "$remote" "$remark"
      starts+=("$start"); ends+=("$end")
    fi
  done <<<"$rows"

  ((${#starts[@]})) || { echo "没有匹配的索引。"; return 1; }
  read -rp "确认删除这些节点？(y/N): " yn
  [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]] || { echo "已取消。"; return 0; }

  backup_file "$CONF_FILE"

  local starts_csv ends_csv
  starts_csv="$(IFS=, ; echo "${starts[*]}")"
  ends_csv="$(IFS=, ; echo "${ends[*]}")"

  if ! awk -v S="$starts_csv" -v E="$ends_csv" '
    BEGIN{
      ns=split(S, s, /,/); ne=split(E, e, /,/);
      for(i=1;i<=ns && i<=ne;i++){
        ss[i]=s[i]+0; ee[i]=e[i]+0;
        if (ee[i] < ss[i]) { tmp=ss[i]; ss[i]=ee[i]; ee[i]=tmp; }
      }
      n= (ns<ne?ns:ne);
    }
    {
      drop=0;
      for(i=1;i<=n;i++){
        if (NR>=ss[i] && NR<=ee[i]) { drop=1; break; }
      }
      if (!drop) print $0;
    }
  ' "$CONF_FILE" > "${CONF_FILE}.tmp.$$"; then
    err "删除过程失败（awk）。"; rm -f "${CONF_FILE}.tmp.$$"; return 1
  fi

  mv "${CONF_FILE}.tmp.$$" "$CONF_FILE"
  log "删除完成。"
  systemctl restart "${APP_NAME}" 2>/dev/null || warn "重启服务失败，查看：journalctl -u ${APP_NAME} -e"
}

show_endpoints_interactive(){ list_endpoints; }

show_status_menu(){
  show_status
  echo
  show_endpoints_interactive
}

main_menu(){
  while true; do
    echo
    echo "==== ${APP_NAME} 管理 ===="
    echo "1) 全新安装 / 首次安装"
    echo "2) 升级（仅覆盖二进制，保留配置）【推荐】"
    echo "3) 升级（覆盖二进制 + 覆盖配置为模板）"
    echo "4) 卸载（可选是否保留配置）"
    echo "5) 查看状态（含节点列表）"
    echo "6) 添加转发节点（带备注）"
    echo "7) 删除/批量删除转发节点（显示备注）"
    echo "q) 退出"
    read -rp "请选择: " op
    case "$op" in
      1) install_fresh ;;
      2) upgrade_inplace "no" ;;
      3) upgrade_inplace "yes" ;;
      4)
        echo "  1) 卸载程序（保留 /etc/realm 配置）"
        echo "  2) 卸载程序（并删除 /etc/realm 配置）"
        read -rp "[1/2, 默认1]: " c; c="${c:-1}"
        [[ "$c" == "2" ]] && uninstall_keep_or_purge "yes" || uninstall_keep_or_purge "no"
        ;;
      5) show_status_menu ;;
      6) add_endpoint_interactive ;;
      7) delete_endpoints_interactive ;;
      q|Q) break ;;
      *) warn "无效选择";;
    esac
  done
}

# ===== 参数解析（非交互模式） =====
if [[ $# -gt 0 ]]; then
  require_root
  ensure_cmds
  case "$1" in
    --install) install_fresh ;;
    --upgrade)
      shift || true
      if [[ "${1:-}" == "--reset-config" ]]; then
        upgrade_inplace "yes"
      else
        upgrade_inplace "no"
      fi
      ;;
    --uninstall)
      shift || true
      if [[ "${1:-}" == "--purge" ]]; then
        uninstall_keep_or_purge "yes"
      else
        uninstall_keep_or_purge "no"
      fi
      ;;
    --status) show_status_menu ;;
    *)
      err "未知参数：$*  可用：--install | --upgrade [--keep-config|--reset-config] | --uninstall [--purge] | --status"
      exit 1
      ;;
  esac
  exit 0
fi

# ===== 交互入口 =====
require_root
ensure_cmds
main_menu

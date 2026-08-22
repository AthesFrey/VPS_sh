#!/usr/bin/env bash
# Realm 安装 / 升级 / 卸载 / 节点管理脚本 v4.0
# 面向 Realm 2.9.x 当前配置与发布格式，不包含旧配置转换逻辑。

set -Eeuo pipefail

APP_NAME="realm"
BIN_DIR="/usr/local/bin"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
CONF_FILE="${CONF_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
RELEASE_API="https://api.github.com/repos/zhboner/realm/releases/latest"

TMP_DIR=""
TGZ_PATH=""
STAGED_BIN=""
RELEASE_JSON=""
LATEST_TAG=""
LATEST_ASSET_URL=""
LATEST_SHA256=""
ARCHIVE_MEMBER=""

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
REALM_MAXTIME="${REALM_MAXTIME:-120}"
REALM_SPEED_LIMIT="${REALM_SPEED_LIMIT:-8192}"
REALM_SPEED_TIME="${REALM_SPEED_TIME:-20}"

CURL_OPTS=(
  -fL
  --retry 2
  --retry-delay 1
  --retry-connrefused
  --connect-timeout "${CURL_CONNECT_TIMEOUT}"
  --max-time "${REALM_MAXTIME}"
  --speed-limit "${REALM_SPEED_LIMIT}"
  --speed-time "${REALM_SPEED_TIME}"
  --proto '=https'
  --tlsv1.2
)
if [[ "${REALM_FORCE_IPV4:-0}" == "1" ]]; then
  CURL_OPTS+=(-4)
fi

log()  { command printf '\033[1;32m[i]\033[0m %s\n' "$*" >&2; }
warn() { command printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { command printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

cleanup() {
  if [[ -n "${TMP_DIR}" && "${TMP_DIR}" == /tmp/realm-setup.* && -d "${TMP_DIR}" ]]; then
    rm -rf -- "${TMP_DIR}" || true
  fi
  TMP_DIR=""
  TGZ_PATH=""
  STAGED_BIN=""
  RELEASE_JSON=""
}
trap cleanup EXIT

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "请以 root 运行（可先执行 sudo -i）。"
    exit 1
  fi
}

ensure_supported_system() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    err "本脚本仅支持使用 systemd 的 Linux。"
    exit 2
  fi
  if [[ ! -d /run/systemd/system ]]; then
    err "当前系统未由 systemd 管理，无法安全安装 Realm 服务。"
    exit 2
  fi
}

ensure_cmds() {
  local required=(awk cmp cp curl grep install mktemp mv rm sed sha256sum systemctl tar uname)
  local missing=()
  local command_name

  for command_name in "${required[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done

  if ((${#missing[@]} == 0)); then
    return 0
  fi

  warn "缺少依赖：${missing[*]}，尝试自动安装。"
  if ! command -v apt-get >/dev/null 2>&1; then
    err "当前系统没有 apt-get，请先手动安装上述命令。"
    exit 3
  fi

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates coreutils curl gawk grep sed systemd tar

  missing=()
  for command_name in "${required[@]}"; do
    command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
  done
  if ((${#missing[@]})); then
    err "依赖安装后仍缺少：${missing[*]}"
    exit 3
  fi
}

prepare_workspace() {
  cleanup
  TMP_DIR="$(mktemp -d /tmp/realm-setup.XXXXXX)" || return 1
  TGZ_PATH="${TMP_DIR}/realm.tar.gz"
  STAGED_BIN="${TMP_DIR}/realm"
  RELEASE_JSON="${TMP_DIR}/release.json"
}

detect_asset() {
  case "$(uname -m)" in
    x86_64|amd64)
      command printf '%s\n' "realm-x86_64-unknown-linux-gnu.tar.gz"
      ;;
    aarch64|arm64)
      command printf '%s\n' "realm-aarch64-unknown-linux-gnu.tar.gz"
      ;;
    armv7l|armv7)
      command printf '%s\n' "realm-armv7-unknown-linux-gnueabihf.tar.gz"
      ;;
    *)
      err "暂不支持 CPU 架构：$(uname -m)"
      return 1
      ;;
  esac
}

fetch_release_metadata() {
  local asset="$1"
  local asset_record digest url

  log "获取 Realm 官方最新发行信息……"
  if ! curl "${CURL_OPTS[@]}" -H 'Accept: application/vnd.github+json' \
    -o "${RELEASE_JSON}" "${RELEASE_API}"; then
    err "无法获取 GitHub 官方发行信息。"
    return 1
  fi

  LATEST_TAG="$(
    awk '
      /^[[:space:]]*"tag_name"[[:space:]]*:/ {
        value=$0
        sub(/^.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/".*$/, "", value)
        print value
        exit
      }
    ' "${RELEASE_JSON}"
  )"

  asset_record="$(
    awk -v wanted="${asset}" '
      index($0, "\"name\": \"" wanted "\"") { found=1 }
      found && /"digest"[[:space:]]*:/ {
        value=$0
        sub(/^.*"digest"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/".*$/, "", value)
        digest=value
      }
      found && /"browser_download_url"[[:space:]]*:/ {
        value=$0
        sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/".*$/, "", value)
        print digest "|" value
        exit
      }
    ' "${RELEASE_JSON}"
  )"

  digest="${asset_record%%|*}"
  url="${asset_record#*|}"
  if [[ -z "${LATEST_TAG}" || -z "${asset_record}" || "${digest}" != sha256:* || "${url}" != https://* ]]; then
    err "官方发行信息中缺少 ${asset} 或其 SHA-256，已停止安装。"
    return 1
  fi

  LATEST_SHA256="${digest#sha256:}"
  LATEST_ASSET_URL="${url}"
  log "官方最新稳定版：${LATEST_TAG}（${asset}）"
}

download_archive() {
  local urls=()
  local prefix="${REALM_GITHUB_PROXY:-}"
  local url

  if [[ -n "${prefix}" ]]; then
    if [[ "${prefix}" != https://* ]]; then
      err "REALM_GITHUB_PROXY 必须是 https:// 开头的代理前缀。"
      return 1
    fi
    [[ "${prefix}" == */ ]] || prefix+="/"
    urls+=("${prefix}${LATEST_ASSET_URL}")
  fi

  # 第三方镜像只负责传输；下载结果仍强制匹配 GitHub 官方 SHA-256。
  urls+=(
    "https://ghfast.top/${LATEST_ASSET_URL}"
    "https://gh-proxy.com/${LATEST_ASSET_URL}"
    "${LATEST_ASSET_URL}"
  )

  for url in "${urls[@]}"; do
    log "尝试下载：${url}"
    rm -f -- "${TGZ_PATH}"
    if curl "${CURL_OPTS[@]}" -o "${TGZ_PATH}" "${url}"; then
      if [[ -s "${TGZ_PATH}" ]] && \
        command printf '%s  %s\n' "${LATEST_SHA256}" "${TGZ_PATH}" | sha256sum -c - >/dev/null 2>&1; then
        log "SHA-256 校验通过。"
        return 0
      fi
      warn "下载文件与 GitHub 官方 SHA-256 不一致，切换下载源。"
    else
      warn "下载失败，切换下载源。"
    fi
  done

  err "所有下载源均失败，或文件完整性校验未通过。"
  return 1
}

extract_and_verify_binary() {
  local archive_list members member_count version_output

  if ! archive_list="$(tar -tzf "${TGZ_PATH}" 2>/dev/null)"; then
    err "发行包不是有效的 tar.gz 文件。"
    return 1
  fi

  if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"${archive_list}"; then
    err "发行包包含不安全路径，已拒绝解包。"
    return 1
  fi

  members="$(awk '$0 == "realm" || $0 == "./realm" { print }' <<<"${archive_list}")"
  member_count="$(command printf '%s\n' "${members}" | awk 'NF { count++ } END { print count+0 }')"
  if [[ "${member_count}" -ne 1 ]]; then
    err "发行包内没有唯一的 realm 可执行文件。"
    return 1
  fi
  ARCHIVE_MEMBER="$(command printf '%s\n' "${members}" | sed -n '1p')"

  # 只读取目标文件内容，不恢复压缩包中的构建机 UID/GID。
  if ! tar -xOzf "${TGZ_PATH}" "${ARCHIVE_MEMBER}" >"${STAGED_BIN}"; then
    err "提取 realm 可执行文件失败。"
    return 1
  fi
  chmod 0755 "${STAGED_BIN}" || return 1

  if ! version_output="$("${STAGED_BIN}" --version 2>&1)"; then
    err "下载的 realm 无法在当前系统运行。"
    return 1
  fi
  if [[ "${version_output}" != Realm\ * ]]; then
    err "下载文件的版本输出异常：${version_output}"
    return 1
  fi
  log "二进制验证通过：${version_output%%$'\n'*}"
}

current_version() {
  if [[ ! -x "${BIN_PATH}" ]]; then
    command printf '%s\n' "（未安装）"
    return 0
  fi
  if ! "${BIN_PATH}" --version 2>/dev/null | sed -n '1p'; then
    command printf '%s\n' "（已安装，但无法读取版本）"
  fi
}

new_backup_path() {
  local source="$1"
  local stamp candidate suffix=0

  stamp="$(date +%F-%H%M%S)"
  candidate="${source}.bak.${stamp}"
  while [[ -e "${candidate}" ]]; do
    ((suffix += 1))
    candidate="${source}.bak.${stamp}.${suffix}"
  done
  command printf '%s\n' "${candidate}"
}

backup_file() {
  local source="$1"
  local backup

  [[ -e "${source}" ]] || return 0
  backup="$(new_backup_path "${source}")"
  cp -a -- "${source}" "${backup}" || return 1
  log "已备份：${source} -> ${backup}"
  command printf '%s\n' "${backup}"
}

restore_backup() {
  local backup="$1"
  local target="$2"

  [[ -n "${backup}" && -e "${backup}" ]] || return 1
  rm -rf -- "${target}" || return 1
  cp -a -- "${backup}" "${target}"
}

make_default_config() {
  local target="$1"
  cat >"${target}" <<'EOF'
# Realm 2.9.x 配置

[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = false

# 转发节点由本脚本菜单添加；也可参照下列格式手动填写：
# # remark: 示例节点
# [[endpoints]]
# listen = "0.0.0.0:3568"
# remote = "127.0.0.1:8080"
# network = { use_udp = false }
EOF
}

write_default_config_if_missing() {
  local candidate

  mkdir -p "${CONF_DIR}" || return 1
  if [[ -s "${CONF_FILE}" ]]; then
    log "保留现有配置：${CONF_FILE}"
    return 0
  fi

  candidate="$(mktemp "${CONF_DIR}/config.toml.new.XXXXXX")" || return 1
  if ! make_default_config "${candidate}" || ! install -m 0644 "${candidate}" "${CONF_FILE}"; then
    rm -f -- "${candidate}" || true
    return 1
  fi
  rm -f -- "${candidate}"
  log "已生成 Realm 2.9.x 默认配置：${CONF_FILE}"
}

write_service() {
  local candidate backup=""

  mkdir -p "$(dirname "${SERVICE_FILE}")" || return 1
  candidate="$(mktemp "$(dirname "${SERVICE_FILE}")/realm.service.new.XXXXXX")" || return 1
  if ! cat >"${candidate}" <<EOF
[Unit]
Description=Realm relay service
Wants=network-online.target
After=network-online.target nss-lookup.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${BIN_PATH} --config ${CONF_FILE}
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=1048576
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
  then
    rm -f -- "${candidate}" || true
    return 1
  fi

  if [[ -f "${SERVICE_FILE}" ]] && cmp -s "${candidate}" "${SERVICE_FILE}"; then
    rm -f -- "${candidate}"
    log "systemd 单元无需更新。"
    return 0
  fi

  if [[ -e "${SERVICE_FILE}" ]]; then
    if ! backup="$(backup_file "${SERVICE_FILE}")"; then
      rm -f -- "${candidate}" || true
      return 1
    fi
  fi
  if ! install -m 0644 "${candidate}" "${SERVICE_FILE}"; then
    rm -f -- "${candidate}"
    [[ -n "${backup}" ]] && restore_backup "${backup}" "${SERVICE_FILE}" || true
    return 1
  fi
  rm -f -- "${candidate}"
  log "已写入 systemd 单元：${SERVICE_FILE}"
}

config_has_endpoints() {
  [[ -s "${CONF_FILE}" ]] && grep -Eq '^[[:space:]]*\[\[endpoints\]\][[:space:]]*(#.*)?$' "${CONF_FILE}"
}

activate_service() {
  systemctl daemon-reload || return 1
  systemctl enable "${APP_NAME}" >/dev/null || return 1

  if ! config_has_endpoints; then
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    log "当前没有转发节点：服务已启用，但暂不启动。添加节点后会自动启动。"
    return 0
  fi

  if systemctl is-active --quiet "${APP_NAME}"; then
    systemctl restart "${APP_NAME}" || return 1
  else
    systemctl start "${APP_NAME}" || return 1
  fi
  if ! systemctl is-active --quiet "${APP_NAME}"; then
    err "Realm 服务未保持运行，请查看：journalctl -u ${APP_NAME} -e --no-pager"
    return 1
  fi
}

install_binary() {
  local candidate="${BIN_PATH}.new.$$"

  mkdir -p "${BIN_DIR}" || return 1
  rm -f -- "${candidate}" || return 1
  if ! install -m 0755 "${STAGED_BIN}" "${candidate}" || ! mv -f -- "${candidate}" "${BIN_PATH}"; then
    rm -f -- "${candidate}" || true
    return 1
  fi
  log "已安装二进制：${BIN_PATH}"
}

install_or_upgrade() {
  local reset_config="${1:-no}"
  local asset binary_backup="" config_backup="" config_candidate=""
  local had_binary=0

  asset="$(detect_asset)" || return 1
  prepare_workspace
  fetch_release_metadata "${asset}" || return 1
  download_archive || return 1
  extract_and_verify_binary || return 1

  [[ -x "${BIN_PATH}" ]] && had_binary=1
  if ((had_binary)); then
    log "当前版本：$(current_version)"
    binary_backup="$(backup_file "${BIN_PATH}")" || return 1
  fi

  mkdir -p "${CONF_DIR}" || return 1
  if [[ "${reset_config}" == "yes" ]]; then
    if [[ -e "${CONF_FILE}" ]]; then
      config_backup="$(backup_file "${CONF_FILE}")" || return 1
    fi
    config_candidate="$(mktemp "${CONF_DIR}/config.toml.new.XXXXXX")" || return 1
    if ! make_default_config "${config_candidate}" || ! install -m 0644 "${config_candidate}" "${CONF_FILE}"; then
      rm -f -- "${config_candidate}" || true
      return 1
    fi
    rm -f -- "${config_candidate}"
    log "配置已重置为 Realm 2.9.x 模板。"
  else
    write_default_config_if_missing || return 1
  fi

  systemctl stop "${APP_NAME}" 2>/dev/null || true
  if ! install_binary || ! write_service || ! activate_service; then
    err "安装/升级未成功，正在恢复原状态。"
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    if ((had_binary)) && [[ -n "${binary_backup}" ]]; then
      restore_backup "${binary_backup}" "${BIN_PATH}" || true
    elif ((had_binary == 0)); then
      rm -f -- "${BIN_PATH}"
    fi
    if [[ "${reset_config}" == "yes" ]]; then
      if [[ -n "${config_backup}" ]]; then
        restore_backup "${config_backup}" "${CONF_FILE}" || true
      else
        rm -f -- "${CONF_FILE}"
      fi
    fi
    systemctl daemon-reload 2>/dev/null || true
    if ((had_binary)) && config_has_endpoints; then
      systemctl start "${APP_NAME}" 2>/dev/null || true
    fi
    return 1
  fi

  log "安装/升级完成。当前版本：$(current_version)"
}

uninstall_realm() {
  local purge="${1:-no}"
  local archived_config=""

  systemctl stop "${APP_NAME}" 2>/dev/null || true
  systemctl disable "${APP_NAME}" >/dev/null 2>&1 || true

  if [[ -e "${SERVICE_FILE}" ]]; then
    rm -f -- "${SERVICE_FILE}"
    log "已删除 systemd 单元：${SERVICE_FILE}"
  fi
  if [[ -e "${BIN_PATH}" ]]; then
    rm -f -- "${BIN_PATH}"
    log "已删除二进制：${BIN_PATH}"
  fi
  systemctl daemon-reload
  systemctl reset-failed "${APP_NAME}" 2>/dev/null || true

  if [[ "${purge}" == "yes" && -d "${CONF_DIR}" ]]; then
    archived_config="$(new_backup_path "${CONF_DIR}")"
    mv -- "${CONF_DIR}" "${archived_config}"
    log "配置目录已移至可恢复备份：${archived_config}"
  elif [[ -d "${CONF_DIR}" ]]; then
    log "已保留配置目录：${CONF_DIR}"
  fi

  log "卸载完成。"
}

ensure_config() {
  mkdir -p "${CONF_DIR}" || return 1
  write_default_config_if_missing
}

# 输出：idx|start|end|remark|listen|remote|udp
parse_endpoints() {
  ensure_config || return 1
  awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function quoted_value(value) {
      sub(/^[^"]*"/, "", value)
      sub(/".*$/, "", value)
      return trim(value)
    }
    function flush_block(end_line) {
      if (!in_block) return
      index_count++
      gsub(/\|/, "/", remark)
      printf "%d|%d|%d|%s|%s|%s|%s\n", index_count, start_line, end_line, remark, listen, remote, udp
      in_block=0
      start_line=0
      remark=""
      listen=""
      remote=""
      udp="false"
    }
    BEGIN {
      index_count=0
      in_block=0
      pending_remark=""
      pending_line=0
    }
    {
      line=$0

      if (line ~ /^[[:space:]]*#[[:space:]]*remark[[:space:]]*:/) {
        if (in_block) flush_block(NR-1)
        value=line
        sub(/^[[:space:]]*#[[:space:]]*remark[[:space:]]*:[[:space:]]*/, "", value)
        pending_remark=trim(value)
        pending_line=NR
        next
      }

      if (line ~ /^[[:space:]]*\[\[endpoints\]\][[:space:]]*(#.*)?$/) {
        if (in_block) flush_block(NR-1)
        in_block=1
        start_line=(pending_line == NR-1 ? pending_line : NR)
        remark=pending_remark
        listen=""
        remote=""
        udp="false"
        pending_remark=""
        pending_line=0
        next
      }

      if (in_block && line ~ /^[[:space:]]*\[/) {
        flush_block(NR-1)
      }

      if (in_block) {
        if (line ~ /^[[:space:]]*listen[[:space:]]*=/) listen=quoted_value(line)
        if (line ~ /^[[:space:]]*remote[[:space:]]*=/) remote=quoted_value(line)
        if (line ~ /use_udp[[:space:]]*=[[:space:]]*true/) udp="true"
        next
      }

      if (line !~ /^[[:space:]]*(#.*)?$/) {
        pending_remark=""
        pending_line=0
      }
    }
    END {
      if (in_block) flush_block(NR)
    }
  ' "${CONF_FILE}"
}

list_endpoints() {
  local rows
  rows="$(parse_endpoints)" || return 1
  if [[ -z "${rows}" ]]; then
    echo "（暂无 [[endpoints]] 转发节点）"
    return 0
  fi

  command printf '%s\n' "Idx  协议     Listen                       -> Remote                       | Remark"
  command printf '%s\n' "---- -------- ----------------------------    ---------------------------- | -----------------------------"
  while IFS='|' read -r index _start _end remark listen remote udp; do
    [[ -n "${remark}" ]] || remark="null-remark"
    local protocol="TCP"
    [[ "${udp}" == "true" ]] && protocol="TCP+UDP"
    command printf '%-4s %-8s %-28s -> %-28s | %s\n' \
      "${index}" "${protocol}" "${listen:--}" "${remote:--}" "${remark}"
  done <<<"${rows}"
}

valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] && ((10#${port} >= 1 && 10#${port} <= 65535))
}

valid_ipv4() {
  local address="$1"
  local octets=()
  local octet

  IFS='.' read -r -a octets <<<"${address}"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#${octet} <= 255)) || return 1
  done
}

validate_listen() {
  local value="$1" host port

  if [[ "${value}" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]{1,5})$ ]]; then
    valid_port "${BASH_REMATCH[2]}"
    return
  fi
  if [[ "${value}" =~ ^([0-9.]+):([0-9]{1,5})$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    valid_ipv4 "${host}" && valid_port "${port}"
    return
  fi
  return 1
}

validate_remote() {
  local value="$1" host port

  if [[ "${value}" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]{1,5})$ ]]; then
    valid_port "${BASH_REMATCH[2]}"
    return
  fi
  if [[ "${value}" =~ ^([A-Za-z0-9._-]+):([0-9]{1,5})$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    if [[ "${host}" =~ ^[0-9.]+$ ]]; then
      valid_ipv4 "${host}" && valid_port "${port}"
      return
    fi
    [[ -n "${host}" && "${host}" != .* && "${host}" != *. && "${host}" != *..* ]] && valid_port "${port}"
    return
  fi
  return 1
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  command printf '%s' "${value}"
}

normalize_listen() {
  local value
  value="$(trim "$1")"
  if [[ "${value}" =~ ^[0-9]{1,5}$ ]]; then
    command printf '0.0.0.0:%s\n' "${value}"
  else
    command printf '%s\n' "${value}"
  fi
}

restart_after_config_change() {
  if [[ ! -x "${BIN_PATH}" || ! -f "${SERVICE_FILE}" ]]; then
    log "配置已保存；安装 Realm 后服务才会启动。"
    return 0
  fi

  systemctl daemon-reload || return 1
  if ! config_has_endpoints; then
    systemctl stop "${APP_NAME}" 2>/dev/null || true
    log "已无转发节点，Realm 服务已停止。"
    return 0
  fi

  if ! systemctl restart "${APP_NAME}" || ! systemctl is-active --quiet "${APP_NAME}"; then
    return 1
  fi
}

commit_config() {
  local candidate="$1"
  local description="$2"
  local backup

  backup="$(backup_file "${CONF_FILE}")" || return 1
  install -m 0644 "${candidate}" "${CONF_FILE}" || return 1

  if restart_after_config_change; then
    log "${description}"
    return 0
  fi

  err "新配置导致 Realm 启动失败，正在自动回滚。"
  restore_backup "${backup}" "${CONF_FILE}" || {
    err "配置自动回滚失败，请从备份恢复：${backup}"
    return 1
  }
  restart_after_config_change || warn "旧配置恢复后服务仍未启动，请检查 journalctl。"
  return 1
}

add_endpoint_interactive() {
  ensure_config || return 1
  while true; do
    local listen remote remark udp_answer use_udp candidate continue_answer

    while true; do
      read -rp "监听端口/地址（如 3569 或 0.0.0.0:3569；IPv6 用 [::]:3569）: " listen
      listen="$(normalize_listen "${listen}")"
      validate_listen "${listen}" && break
      echo "格式不正确：监听地址必须是 IPv4:端口、[IPv6]:端口，或只输入端口。"
    done

    while true; do
      read -rp "后端地址（如 127.0.0.1:8080、example.com:443 或 [::1]:8080）: " remote
      remote="$(trim "${remote}")"
      validate_remote "${remote}" && break
      echo "格式不正确：请输入 IP/域名:端口；IPv6 必须写成 [IPv6]:端口。"
    done

    read -rp "是否同时转发 UDP？(y/N): " udp_answer
    udp_answer="${udp_answer:-N}"
    udp_answer="${udp_answer,,}"
    use_udp="false"
    [[ "${udp_answer}" == "y" || "${udp_answer}" == "yes" ]] && use_udp="true"

    read -rp "备注 remark（可留空）: " remark
    remark="$(trim "${remark}")"
    remark="${remark//|//}"

    candidate="$(mktemp "${CONF_DIR}/config.toml.new.XXXXXX")" || return 1
    if ! cp -- "${CONF_FILE}" "${candidate}"; then
      rm -f -- "${candidate}" || true
      return 1
    fi
    if ! {
      command printf '\n# remark: %s\n' "${remark}"
      command printf '%s\n' '[[endpoints]]'
      command printf 'listen = "%s"\n' "${listen}"
      command printf 'remote = "%s"\n' "${remote}"
      command printf 'network = { use_udp = %s }\n' "${use_udp}"
    } >>"${candidate}"; then
      rm -f -- "${candidate}" || true
      return 1
    fi

    if ! commit_config "${candidate}" "已添加节点：${listen} -> ${remote}（UDP=${use_udp}）"; then
      rm -f -- "${candidate}"
      return 1
    fi
    rm -f -- "${candidate}"

    read -rp "继续添加下一个节点吗？(y/N): " continue_answer
    continue_answer="${continue_answer:-N}"
    continue_answer="${continue_answer,,}"
    [[ "${continue_answer}" == "y" || "${continue_answer}" == "yes" ]] || break
  done
}

delete_endpoints_interactive() {
  ensure_config || return 1
  local rows selection normalized count candidate backup_answer
  local parts=() starts=() ends=()
  local part first last swap index start end remark listen remote udp
  declare -A selected=()

  rows="$(parse_endpoints)" || return 1
  if [[ -z "${rows}" ]]; then
    echo "当前没有可删除的节点。"
    return 0
  fi

  list_endpoints
  echo
  read -rp "输入要删除的索引（支持逗号和区间，如 1,3,5-7）: " selection
  normalized="${selection//[[:space:]]/}"
  if [[ ! "${normalized}" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
    err "索引格式无效。"
    return 1
  fi

  count="$(command printf '%s\n' "${rows}" | awk 'NF { count++ } END { print count+0 }')"
  IFS=',' read -r -a parts <<<"${normalized}"
  for part in "${parts[@]}"; do
    if [[ "${part}" == *-* ]]; then
      first="${part%-*}"
      last="${part#*-}"
    else
      first="${part}"
      last="${part}"
    fi
    if ((${#first} > 9 || ${#last} > 9)); then
      err "索引数字过大：${part}"
      return 1
    fi
    ((10#${first} >= 1 && 10#${first} <= count && 10#${last} >= 1 && 10#${last} <= count)) || {
      err "索引超出范围：${part}（有效范围 1-${count}）"
      return 1
    }
    if ((10#${first} > 10#${last})); then
      swap="${first}"
      first="${last}"
      last="${swap}"
    fi
    for ((index=10#${first}; index<=10#${last}; index++)); do
      selected["${index}"]=1
    done
  done

  while IFS='|' read -r index start end remark listen remote udp; do
    if [[ -n "${selected[${index}]:-}" ]]; then
      [[ -n "${remark}" ]] || remark="null-remark"
      command printf '将删除 #%s: %s -> %s | %s\n' "${index}" "${listen}" "${remote}" "${remark}"
      starts+=("${start}")
      ends+=("${end}")
    fi
  done <<<"${rows}"

  read -rp "确认删除这些节点？(y/N): " backup_answer
  backup_answer="${backup_answer:-N}"
  backup_answer="${backup_answer,,}"
  [[ "${backup_answer}" == "y" || "${backup_answer}" == "yes" ]] || {
    echo "已取消。"
    return 0
  }

  local starts_csv ends_csv
  starts_csv="$(IFS=,; command printf '%s' "${starts[*]}")"
  ends_csv="$(IFS=,; command printf '%s' "${ends[*]}")"
  candidate="$(mktemp "${CONF_DIR}/config.toml.new.XXXXXX")" || return 1

  if ! awk -v starts_csv="${starts_csv}" -v ends_csv="${ends_csv}" '
    BEGIN {
      start_count=split(starts_csv, starts, /,/)
      end_count=split(ends_csv, ends, /,/)
      count=(start_count < end_count ? start_count : end_count)
    }
    {
      drop=0
      for (i=1; i<=count; i++) {
        if (NR >= starts[i]+0 && NR <= ends[i]+0) {
          drop=1
          break
        }
      }
      if (!drop) print
    }
  ' "${CONF_FILE}" >"${candidate}"; then
    rm -f -- "${candidate}"
    err "生成删除后的配置失败。"
    return 1
  fi

  if ! commit_config "${candidate}" "所选节点已删除。"; then
    rm -f -- "${candidate}"
    return 1
  fi
  rm -f -- "${candidate}"
}

show_status() {
  local service_state="inactive"
  local enable_state="disabled"

  systemctl is-active --quiet "${APP_NAME}" 2>/dev/null && service_state="active"
  systemctl is-enabled --quiet "${APP_NAME}" 2>/dev/null && enable_state="enabled"

  echo "二进制：${BIN_PATH}"
  echo "版本：$(current_version)"
  echo "配置：${CONF_FILE} $( [[ -s "${CONF_FILE}" ]] && echo '（存在）' || echo '（缺失或空）' )"
  echo "服务：${service_state} / ${enable_state}"
  echo
  list_endpoints
}

usage() {
  cat <<EOF
用法：
  $0                         打开交互菜单
  $0 --install               安装/重装最新稳定版，保留已有配置
  $0 --upgrade               升级最新稳定版，保留已有配置
  $0 --upgrade --reset-config
                             升级并将配置重置为新版模板
  $0 --uninstall             卸载程序，保留配置
  $0 --uninstall --purge     卸载程序，配置移至带时间戳的备份目录
  $0 --status                查看版本、服务状态和节点
  $0 --help                  显示本帮助

可选环境变量：
  REALM_FORCE_IPV4=1         下载时强制 IPv4
  REALM_GITHUB_PROXY=https://example.com/
                             自定义 GitHub 下载代理前缀
EOF
}

main_menu() {
  local option uninstall_option

  while true; do
    echo
    echo "==== Realm 2.9.x 管理 ===="
    echo "1) 安装 / 重装最新稳定版（保留配置）"
    echo "2) 升级最新稳定版（保留配置）【推荐】"
    echo "3) 升级并重置为新版配置模板"
    echo "4) 卸载"
    echo "5) 查看状态与节点"
    echo "6) 添加转发节点"
    echo "7) 删除 / 批量删除转发节点"
    echo "q) 退出"
    read -rp "请选择: " option

    case "${option}" in
      1) install_or_upgrade "no" ;;
      2) install_or_upgrade "no" ;;
      3) install_or_upgrade "yes" ;;
      4)
        echo "  1) 卸载程序，保留 ${CONF_DIR}"
        echo "  2) 卸载程序，并将配置移至备份目录"
        read -rp "[1/2，默认 1]: " uninstall_option
        uninstall_option="${uninstall_option:-1}"
        if [[ "${uninstall_option}" == "2" ]]; then
          uninstall_realm "yes"
        else
          uninstall_realm "no"
        fi
        ;;
      5) show_status ;;
      6) add_endpoint_interactive ;;
      7) delete_endpoints_interactive ;;
      q|Q) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return 0
  fi

  require_root
  ensure_supported_system
  ensure_cmds

  case "${1:-}" in
    "")
      main_menu
      ;;
    --install)
      [[ $# -eq 1 ]] || { err "--install 不接受其他参数。"; return 1; }
      install_or_upgrade "no"
      ;;
    --upgrade)
      if [[ $# -eq 1 ]]; then
        install_or_upgrade "no"
      elif [[ $# -eq 2 && "$2" == "--reset-config" ]]; then
        install_or_upgrade "yes"
      else
        err "--upgrade 仅支持可选参数 --reset-config。"
        return 1
      fi
      ;;
    --uninstall)
      if [[ $# -eq 1 ]]; then
        uninstall_realm "no"
      elif [[ $# -eq 2 && "$2" == "--purge" ]]; then
        uninstall_realm "yes"
      else
        err "--uninstall 仅支持可选参数 --purge。"
        return 1
      fi
      ;;
    --status)
      [[ $# -eq 1 ]] || { err "--status 不接受其他参数。"; return 1; }
      show_status
      ;;
    *)
      err "未知参数：$*"
      usage
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

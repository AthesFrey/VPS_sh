#!/usr/bin/env bash
# Realm deployment script v3. Official stable releases, Debian 12/13 + systemd.
# Run with bash, not sh. Configuration editing uses the distro's python3-tomlkit.
set -Eeuo pipefail
umask 077

APP_NAME=realm
BIN_DIR=/usr/local/bin
BIN_PATH=${BIN_DIR}/realm
CONF_DIR=/etc/realm
CONF_FILE=${CONF_DIR}/config.toml
SERVICE_FILE=/etc/systemd/system/realm.service
RELEASE_API=https://api.github.com/repos/zhboner/realm/releases/latest
PYTHON=/usr/bin/python3
TMP_DIR=""
EXEC_DIR=""
STAGED_BIN=""
LATEST_TAG=""
LATEST_ASSET_URL=""
LATEST_SHA256=""
TX_ACTIVE=0
TX_WAS_ACTIVE=0
TX_WAS_ENABLED=0
TX_FILES=()
TX_BACKUPS=()

CURL_OPTS=(--fail --location --show-error --silent --retry 2 --retry-delay 1
  --retry-connrefused --connect-timeout "${CURL_CONNECT_TIMEOUT:-10}"
  --max-time "${REALM_MAXTIME:-120}" --speed-limit "${REALM_SPEED_LIMIT:-8192}"
  --speed-time "${REALM_SPEED_TIME:-20}" --proto '=https' --proto-redir '=https' --tlsv1.2)
[[ ${REALM_FORCE_IPV4:-0} != 1 ]] || CURL_OPTS+=(-4)

log() { printf '[i] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
err() { printf '[x] %s\n' "$*" >&2; }

# One embedded helper keeps the delivered script self-contained. Parse structured
# data with JSON/TOML libraries; never infer TOML block ownership from line ranges.
helper() {
  "$PYTHON" - "$@" <<'PY'
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sys
import tarfile


def address(value, listen=False):
    if not isinstance(value, str):
        raise ValueError("地址必须是字符串")
    value = value.strip()
    if listen and re.fullmatch(r"[0-9]{1,5}", value):
        value = "0.0.0.0:" + value
    match = re.fullmatch(r"\[([^\]]+)\]:([0-9]{1,5})", value)
    if match:
        host, port = match.groups()
        if "%" in host:
            raise ValueError("暂不支持 IPv6 zone ID，请使用完整的无 zone 地址")
        host = str(ipaddress.IPv6Address(host))
        host = "[" + host + "]"
    else:
        match = re.fullmatch(r"([^:\s]+):([0-9]{1,5})", value)
        if not match:
            raise ValueError("地址格式应为 IPv4:端口、[IPv6]:端口或域名:端口")
        host, port = match.groups()
        if listen or re.fullmatch(r"[0-9.]+", host):
            host = str(ipaddress.IPv4Address(host))
        else:
            host = host.encode("idna").decode("ascii").lower()
            if len(host) > 253 or not all(
                re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                for label in (host[:-1] if host.endswith(".") else host).split(".")
            ):
                raise ValueError("域名格式无效")
    if not 1 <= int(port) <= 65535:
        raise ValueError("端口必须在 1-65535 之间")
    return "{}:{}".format(host, int(port))


def selected(text, count):
    text = re.sub(r"\s+", "", text)
    if not re.fullmatch(r"[0-9]{1,9}(?:-[0-9]{1,9})?(?:,[0-9]{1,9}(?:-[0-9]{1,9})?)*", text):
        raise ValueError("索引格式无效，请输入 1,3,5-7 这样的索引或区间")
    result = set()
    for part in text.split(","):
        bounds = [int(x) for x in part.split("-")]
        low, high = min(bounds), max(bounds)
        if low < 1 or high > count:
            raise ValueError("索引超出范围，有效范围为 1-{}".format(count))
        result.update(range(low - 1, high))
    return sorted(result)


def endpoints(doc):
    items = doc.get("endpoints")
    if items is None:
        return []
    from tomlkit.items import AoT, Array
    if isinstance(items, Array) and not items:
        return []
    if not isinstance(items, AoT):
        raise ValueError("endpoints 必须使用 [[endpoints]] 配置")
    if not isinstance(items, list) or any(not isinstance(ep, dict) for ep in items):
        raise ValueError("endpoints 必须是 TOML 表数组")
    return items


def protocols(doc, ep):
    global_net = doc.get("network", {})
    net = ep.get("network", {})
    if not isinstance(net, dict) or not isinstance(global_net, dict):
        raise ValueError("network 必须是 TOML 表")
    tcp = not net.get("no_tcp", global_net.get("no_tcp", False))
    udp = net.get("use_udp", global_net.get("use_udp", False))
    return [name for name, enabled in (("TCP", tcp), ("UDP", udp)) if enabled]


def validate(doc):
    for ep in endpoints(doc):
        address(ep.get("listen"), True)
        address(ep.get("remote"))
        for remote in ep.get("extra_remotes", []):
            address(remote)
        protocols(doc, ep)
    for net in [doc.get("network", {})] + [ep.get("network", {}) for ep in endpoints(doc)]:
        for key in ("no_tcp", "use_udp", "ipv6_only"):
            if key in net and not isinstance(net[key], bool):
                raise ValueError("{} 必须是布尔值".format(key))


def bound_sockets(pid):
    inodes = set()
    for fd in Path("/proc/{}/fd".format(pid)).iterdir():
        try:
            target = os.readlink(str(fd))
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    bound = set()
    for name in ("tcp", "tcp6", "udp", "udp6"):
        path = Path("/proc/{}/net/{}".format(pid, name))
        if not path.exists():
            continue
        for line in path.read_text().splitlines()[1:]:
            row = line.split()
            if row[9] not in inodes or row[3] != ("0A" if name.startswith("tcp") else "07"):
                continue
            raw, port = row[1].split(":")
            octets = b"".join(int(raw[i:i + 8], 16).to_bytes(4, sys.byteorder)
                              for i in range(0, len(raw), 8))
            family = socket.AF_INET6 if name.endswith("6") else socket.AF_INET
            host = socket.inet_ntop(family, octets)
            bound.add((name[:3].upper(), host, int(port, 16)))
    return bound


def main():
    cmd, *args = sys.argv[1:]
    if cmd == "release":
        data = json.loads(Path(args[0]).read_text())
        tag = data.get("tag_name", "")
        if data.get("draft") or data.get("prerelease") or not re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", tag):
            raise ValueError("官方发行信息不是有效的稳定版本")
        print(tag)
        return
    if cmd == "asset":
        data = json.loads(Path(args[0]).read_text())
        matches = [a for a in data.get("assets", []) if a.get("name") == args[1]]
        if not matches:
            sys.exit(3)
        if len(matches) != 1:
            raise ValueError("官方发行包名称重复")
        item = matches[0]
        digest = item.get("digest") or ""
        url = item.get("browser_download_url") or ""
        expected = "https://github.com/zhboner/realm/releases/download/{}/{}".format(data["tag_name"], args[1])
        if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest) or url != expected:
            raise ValueError("官方发行包缺少有效 SHA-256 或下载地址异常")
        print(digest[7:].lower() + "|" + url)
        return
    if cmd == "extract":
        with tarfile.open(args[0], "r:gz") as archive:
            members = archive.getmembers()
            if any(m.name.startswith("/") or ".." in m.name.split("/") for m in members):
                raise ValueError("发行包包含不安全路径")
            matches = [m for m in members if m.name in ("realm", "./realm")]
            if len(matches) != 1 or not matches[0].isfile() or not 0 < matches[0].size <= 256 * 1024 * 1024:
                raise ValueError("发行包内没有唯一且有效的 realm 普通文件")
            with archive.extractfile(matches[0]) as source, open(args[1], "wb") as output:
                shutil.copyfileobj(source, output)
        os.chmod(args[1], 0o755)
        return
    if cmd == "address":
        print(address(args[1], args[0] == "listen"))
        return

    import tomlkit
    path = Path(args[0])
    doc = tomlkit.parse(path.read_text(encoding="utf-8"))
    items = endpoints(doc)
    if cmd == "validate":
        validate(doc)
    elif cmd == "count":
        print(len(items))
    elif cmd == "list":
        if not items:
            print("（暂无转发节点）")
        for i, ep in enumerate(items, 1):
            remark = getattr(getattr(ep.get("listen"), "trivia", None), "comment", "")
            remark = re.sub(r"^#\s*remark:\s*", "", remark)
            print("{}) {}  {} -> {}{}".format(i, "+".join(protocols(doc, ep)) or "已禁用",
                  ep.get("listen", "?"), ep.get("remote", "?"), " | " + remark if remark else ""))
    elif cmd == "add":
        listen = address(args[2], True)
        remote = address(args[3])
        if any(address(ep.get("listen"), True) == listen for ep in items):
            raise ValueError("已有相同的监听地址：" + listen)
        if any(ord(c) < 32 or ord(c) == 127 for c in args[5]):
            raise ValueError("备注不能包含控制字符")
        protocol = args[4]
        protocol_values = {
            "tcp": {"no_tcp": False, "use_udp": False},
            "udp": {"no_tcp": True, "use_udp": True},
            "both": {"no_tcp": False, "use_udp": True},
        }
        if protocol not in protocol_values:
            raise ValueError("协议必须是 tcp、udp 或 both")
        ep = tomlkit.table()
        ep.add("listen", listen)
        if args[5]:
            ep["listen"].comment("remark: " + args[5])
        ep.add("remote", remote)
        net = tomlkit.inline_table()
        net.update(protocol_values[protocol])
        ep.add("network", net)
        if "endpoints" not in doc or not isinstance(doc["endpoints"], tomlkit.items.AoT):
            doc["endpoints"] = tomlkit.aot()
        doc["endpoints"].append(ep)
        validate(doc)
        Path(args[1]).write_text(tomlkit.dumps(doc), encoding="utf-8")
    elif cmd in ("select", "delete"):
        indices = selected(args[-1], len(items))
        if cmd == "select":
            print(",".join(str(i + 1) for i in indices))
            return
        for i in reversed(indices):
            del doc["endpoints"][i]
        if not doc["endpoints"]:
            # tomlkit 0.11 (Debian 12) cannot replace an emptied AoT in place.
            # Reparse a valid root empty array so the next add remains supported.
            del doc["endpoints"]
            doc = tomlkit.parse("endpoints = []\n" + tomlkit.dumps(doc))
        validate(doc)
        Path(args[1]).write_text(tomlkit.dumps(doc), encoding="utf-8")
    elif cmd == "health":
        actual = bound_sockets(int(args[1]))
        missing = []
        for ep in items:
            host, port = address(ep["listen"], True).rsplit(":", 1)
            host = host.strip("[]")
            for protocol in protocols(doc, ep):
                if (protocol, host, int(port)) not in actual:
                    missing.append("{} {}".format(protocol, ep["listen"]))
        if missing:
            raise ValueError("Realm 进程尚未监听：" + ", ".join(missing))
    else:
        raise ValueError("未知辅助命令：" + cmd)


try:
    main()
except Exception as exc:
    print("[x] " + str(exc), file=sys.stderr)
    sys.exit(1)
PY
}

ensure_cmds() {
  local mode=${1:-full} command_name
  local required=(curl sha256sum mktemp chmod mkdir rm mv cp date dirname timeout env uname sleep)
  local missing=() packages=(ca-certificates coreutils curl python3)
  if [[ $mode == full ]]; then
    required+=(systemctl flock)
    packages+=(python3-tomlkit util-linux)
  fi
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done
  [[ -x $PYTHON ]] || missing+=(python3)
  if [[ $mode == full ]] && ! "$PYTHON" -c 'import tomlkit' >/dev/null 2>&1; then
    missing+=(python3-tomlkit)
  fi
  if ((${#missing[@]})); then
    if [[ $EUID != 0 ]] || ! command -v apt-get >/dev/null 2>&1; then
      err "缺少依赖：${missing[*]}。请由管理员执行：apt-get update && apt-get install -y ${packages[*]}"
      return 1
    fi
    log "安装所需发行版依赖：${packages[*]}"
    apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" || return 1
  fi
  for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || { err "仍缺少命令：$command_name"; return 1; }
  done
  "$PYTHON" -c 'import json, tarfile, ipaddress' || return 1
  [[ $mode != full ]] || "$PYTHON" -c 'import tomlkit' || return 1
}

cleanup_workspace() {
  if [[ -n $EXEC_DIR && ${EXEC_DIR##*/} == .realm-stage.* ]]; then
    rm -rf -- "$EXEC_DIR"
  fi
  if [[ -n $TMP_DIR && ${TMP_DIR##*/} == realm-v3.* ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  TMP_DIR=""
  EXEC_DIR=""
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  if ((TX_ACTIVE)); then
    rollback_transaction || true
    status=1
  fi
  cleanup_workspace || true
  exit "$status"
}

prepare_workspace() {
  cleanup_workspace || return 1
  TMP_DIR=$(mktemp -d "${REALM_TMPDIR:-${TMPDIR:-/tmp}}/realm-v3.XXXXXX") || return 1
  if [[ ${1:-check} == install ]]; then
    mkdir -p "$BIN_DIR" || return 1
    # Verify on the destination filesystem, even when /tmp is mounted noexec.
    EXEC_DIR=$(mktemp -d "$BIN_DIR/.realm-stage.XXXXXX") || return 1
    STAGED_BIN=$EXEC_DIR/realm
  else
    STAGED_BIN=$TMP_DIR/realm
  fi
}

asset_candidates() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    armv7l|armv7)
      printf '%s\n' realm-armv7-unknown-linux-musleabihf.tar.gz \
        realm-armv7-unknown-linux-gnueabihf-glibc2.28.tar.gz realm-armv7-unknown-linux-gnueabihf.tar.gz
      return 0 ;;
    *) err "暂不支持 CPU 架构：$arch"; return 1 ;;
  esac
  printf 'realm-%s-unknown-linux-%s.tar.gz\n' "$arch" musl "$arch" gnu-glibc2.28 "$arch" gnu
}

download_archive() {
  local prefix=${REALM_GITHUB_PROXY:-} url
  local urls=()
  if [[ -n $prefix ]]; then
    [[ $prefix == https://* && $prefix != *[$'\r\n\t ']* ]] || {
      err "REALM_GITHUB_PROXY 必须是有效的 HTTPS 代理前缀。"; return 1;
    }
    urls+=("${prefix%/}/$LATEST_ASSET_URL")
  fi
  urls+=("$LATEST_ASSET_URL" "https://ghfast.top/$LATEST_ASSET_URL" "https://gh-proxy.com/$LATEST_ASSET_URL")
  for url in "${urls[@]}"; do
    log "尝试下载：$url"
    if curl "${CURL_OPTS[@]}" -o "$TMP_DIR/realm.tar.gz" "$url"; then
      if printf '%s  %s\n' "$LATEST_SHA256" "$TMP_DIR/realm.tar.gz" | sha256sum -c - >/dev/null 2>&1; then
        log "SHA-256 校验通过（GitHub 官方元数据）。"
        return 0
      fi
      warn "SHA-256 不匹配，尝试下一下载源。"
    fi
  done
  err "此发行包的所有下载源均失败。"
  return 1
}

fetch_binary() {
  local candidates asset record version_output expected status
  candidates=$(asset_candidates) || return 1
  log "获取 Realm 官方最新稳定发行信息……"
  curl "${CURL_OPTS[@]}" -H 'Accept: application/vnd.github+json' \
    -o "$TMP_DIR/release.json" "$RELEASE_API" || {
    err "无法获取 GitHub 官方发行信息，请检查网络或 API 访问限额。"; return 1;
  }
  LATEST_TAG=$(helper release "$TMP_DIR/release.json") || return 1
  log "官方最新稳定版：$LATEST_TAG；架构：$(uname -m)；优先使用 musl 构建。"
  while IFS= read -r asset; do
    if record=$(helper asset "$TMP_DIR/release.json" "$asset"); then
      IFS='|' read -r LATEST_SHA256 LATEST_ASSET_URL <<<"$record"
    else
      status=$?
      [[ $status == 3 ]] && warn "本次发行没有 $asset，尝试下一构建。"
      continue
    fi
    log "选择发行包：$asset"
    download_archive || continue
    helper extract "$TMP_DIR/realm.tar.gz" "$STAGED_BIN" || continue
    # REALM_CONF takes precedence over every CLI argument, including --version.
    if version_output=$(timeout 15 env -u REALM_CONF "$STAGED_BIN" --version 2>&1); then
      expected=${LATEST_TAG#v}
      if [[ $version_output =~ ^[Rr]ealm[[:space:]]+([^[:space:]]+) ]] && [[ ${BASH_REMATCH[1]} == "$expected" ]]; then
        log "二进制验证通过：$version_output"
        return 0
      fi
      warn "版本输出与官方标签不符：$version_output"
    else
      status=$?
      warn "$asset 运行失败（退出码 $status）：$version_output"
      if [[ $version_output == *GLIBC_* ]]; then
        warn "此 GNU 构建需要更高版本 glibc，将尝试其他官方构建。"
      elif [[ $status == 126 ]]; then
        warn "请检查执行目录是否挂载为 noexec；下载自检可设置 REALM_TMPDIR 为可执行目录。"
      fi
    fi
  done <<<"$candidates"
  err "未找到可在当前系统运行且通过校验的官方构建，现有程序和配置未替换。"
  return 1
}

current_version() {
  local output
  if [[ ! -x $BIN_PATH ]]; then
    printf '%s\n' '（未安装）'
  elif output=$(timeout 10 env -u REALM_CONF "$BIN_PATH" --version 2>&1); then
    printf '%s\n' "${output%%$'\n'*}"
  else
    printf '（无法运行）%s\n' "$output"
  fi
}

check_managed_paths() {
  local path
  for path in "$BIN_PATH" "$CONF_FILE" "$SERVICE_FILE"; do
    if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
      err "受管理路径不是普通文件，请先检查：$path"
      return 1
    fi
  done
}

backup_file() {
  local source=$1 backup
  backup=$(mktemp "${source}.bak.$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
  if ! cp -p -- "$source" "$backup"; then
    rm -f -- "$backup"
    return 1
  fi
  log "已备份：$backup"
  printf '%s\n' "$backup"
}

atomic_copy() {
  local source=$1 target=$2 candidate
  candidate=$(mktemp "${target}.new.XXXXXX") || return 1
  if ! cp -p -- "$source" "$candidate" || ! mv -f -- "$candidate" "$target"; then
    rm -f -- "$candidate"
    return 1
  fi
}

begin_transaction() {
  local path backup enabled
  TX_FILES=()
  TX_BACKUPS=()
  TX_WAS_ACTIVE=0
  TX_WAS_ENABLED=0
  systemctl is-active --quiet "$APP_NAME" 2>/dev/null && TX_WAS_ACTIVE=1
  enabled=$(systemctl is-enabled "$APP_NAME" 2>/dev/null) || true
  case "$enabled" in
    enabled) TX_WAS_ENABLED=1 ;;
    enabled-runtime) TX_WAS_ENABLED=2 ;;
    masked*) err "Realm 服务已被 mask，请先检查并解除屏蔽。"; return 1 ;;
  esac
  for path in "$@"; do
    backup=""
    if [[ -e $path ]]; then
      backup=$(backup_file "$path") || return 1
    fi
    TX_FILES+=("$path")
    TX_BACKUPS+=("$backup")
  done
  TX_ACTIVE=1
}

rollback_transaction() {
  local i failed=0
  TX_ACTIVE=0
  warn "操作未完成，正在恢复原文件和服务状态。"
  systemctl stop "$APP_NAME" >/dev/null 2>&1 || failed=1
  for ((i=0; i<${#TX_FILES[@]}; i++)); do
    if [[ -n ${TX_BACKUPS[i]} ]]; then
      atomic_copy "${TX_BACKUPS[i]}" "${TX_FILES[i]}" || failed=1
    else
      rm -f -- "${TX_FILES[i]}" || failed=1
    fi
  done
  systemctl daemon-reload || failed=1
  systemctl disable "$APP_NAME" >/dev/null 2>&1 || true
  if ((TX_WAS_ENABLED == 1)); then
    systemctl enable "$APP_NAME" >/dev/null || failed=1
  elif ((TX_WAS_ENABLED == 2)); then
    systemctl enable --runtime "$APP_NAME" >/dev/null || failed=1
  fi
  systemctl reset-failed "$APP_NAME" >/dev/null 2>&1 || true
  if ((TX_WAS_ACTIVE)); then
    systemctl start "$APP_NAME" || failed=1
    wait_service_healthy || failed=1
  fi
  if ((failed)); then
    err "恢复过程中有命令失败，请检查上方备份路径和 systemctl status realm。"
    return 1
  fi
  log "已恢复原文件和服务状态。"
}

make_default_config() {
  printf '%s\n' '# Realm configuration. Add endpoints through realm_v3.sh.' \
    'endpoints = []' '' '[log]' 'level = "warn"' 'output = "stdout"' '' \
    '[network]' 'no_tcp = false' 'use_udp = false' >"$1"
}

write_service() {
  local candidate=$TMP_DIR/realm.service
  if ! cat >"$candidate" <<EOF
[Unit]
Description=Realm relay service
Wants=network-online.target
After=network-online.target nss-lookup.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${BIN_PATH} --config ${CONF_FILE}
UnsetEnvironment=REALM_CONF
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=1048576
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
  then
    return 1
  fi
  chmod 0644 "$candidate" || return 1
  atomic_copy "$candidate" "$SERVICE_FILE"
}

wait_service_healthy() {
  local i pid initial_pid="" restart_count initial_restarts="" state health_error=""
  # Realm may remain alive when just one listener fails. Check socket ownership
  # as well as a stable PID, so a partial bind failure cannot be reported as success.
  for ((i=0; i<5; i++)); do
    sleep 1
    state=$(systemctl is-active "$APP_NAME" 2>/dev/null) || true
    [[ $state == active ]] || { err "Realm 启动后未保持运行（$state）。"; return 1; }
    pid=$(systemctl show "$APP_NAME" --property=MainPID --value) || return 1
    restart_count=$(systemctl show "$APP_NAME" --property=NRestarts --value) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || { err "无法取得 Realm 主进程 PID。"; return 1; }
    if [[ -n $initial_pid && ( $pid != "$initial_pid" || $restart_count != "$initial_restarts" ) ]]; then
      err "Realm 在启动检查期间发生重启。"; return 1
    fi
    initial_pid=$pid
    initial_restarts=$restart_count
    if health_error=$(helper health "$CONF_FILE" "$pid" 2>&1); then
      [[ $i -lt 2 ]] || return 0
    fi
  done
  err "监听检查失败：$health_error"
  return 1
}

activate_service() {
  local count
  count=$(helper count "$CONF_FILE") || return 1
  systemctl daemon-reload || return 1
  if [[ $count == 0 ]]; then
    systemctl stop "$APP_NAME" || return 1
    systemctl disable "$APP_NAME" >/dev/null || return 1
    log "当前没有节点，服务保持停止；添加节点后自动启动并启用开机启动。"
    return 0
  fi
  systemctl enable "$APP_NAME" >/dev/null || return 1
  systemctl reset-failed "$APP_NAME" >/dev/null 2>&1 || true
  systemctl restart "$APP_NAME" || return 1
  wait_service_healthy || {
    err "请查看具体日志：journalctl -u realm -n 50 --no-pager"; return 1;
  }
}

install_or_upgrade() {
  local reset=${1:-no} candidate
  check_managed_paths || return 1
  prepare_workspace install || return 1
  fetch_binary || return 1
  mkdir -p "$CONF_DIR" "$(dirname "$SERVICE_FILE")" || return 1
  candidate=$TMP_DIR/config.toml
  if [[ $reset == yes || ! -e $CONF_FILE ]]; then
    make_default_config "$candidate" || return 1
  else
    cp -p -- "$CONF_FILE" "$candidate" || return 1
    log "保留现有配置和转发节点：$CONF_FILE"
  fi
  helper validate "$candidate" || return 1
  begin_transaction "$BIN_PATH" "$CONF_FILE" "$SERVICE_FILE" || return 1
  # Every failure after this point is handled by the transaction's EXIT trap.
  if ! atomic_copy "$STAGED_BIN" "$BIN_PATH" \
    || ! atomic_copy "$candidate" "$CONF_FILE" \
    || ! write_service || ! activate_service; then
    rollback_transaction || true
    return 1
  fi
  TX_ACTIVE=0
  log "安装/升级完成：$(current_version)"
  cleanup_workspace
}

ensure_config() {
  check_managed_paths || return 1
  mkdir -p "$CONF_DIR" || return 1
  if [[ ! -e $CONF_FILE ]]; then
    prepare_workspace || return 1
    make_default_config "$TMP_DIR/config.toml" || return 1
    atomic_copy "$TMP_DIR/config.toml" "$CONF_FILE" || return 1
  fi
  helper validate "$CONF_FILE"
}

commit_config() {
  local candidate=$1
  helper validate "$candidate" || return 1
  begin_transaction "$CONF_FILE" || return 1
  if ! atomic_copy "$candidate" "$CONF_FILE"; then
    rollback_transaction || true
    return 1
  fi
  if [[ -x $BIN_PATH && -f $SERVICE_FILE ]]; then
    if ! activate_service; then
      rollback_transaction || true
      return 1
    fi
  else
    log "配置已保存，安装 Realm 后生效。"
  fi
  TX_ACTIVE=0
}

confirm() {
  local answer
  read -r -p "$1 (y/N): " answer || return 1
  [[ ${answer,,} == y || ${answer,,} == yes ]]
}

add_endpoint_interactive() {
  local listen remote remark protocol protocol_name candidate
  ensure_config || return 1
  prepare_workspace || return 1
  candidate=$TMP_DIR/config.toml
  while true; do
    while true; do
      read -r -p '监听端口/地址（如 3569、0.0.0.0:3569 或 [::]:3569）: ' listen || return 1
      if listen=$(helper address listen "$listen"); then break; fi
    done
    while true; do
      read -r -p '后端地址（如 127.0.0.1:8080、example.com:443 或 [::1]:8080）: ' remote || return 1
      if remote=$(helper address remote "$remote"); then break; fi
    done
    while true; do
      read -r -p '转发协议：1) TCP  2) UDP  3) TCP+UDP（默认 1）: ' protocol || return 1
      case "${protocol:-1}" in
        1) protocol=tcp; protocol_name=TCP; break ;;
        2) protocol=udp; protocol_name=UDP; break ;;
        3) protocol=both; protocol_name='TCP+UDP'; break ;;
        *) warn '请选择 1、2 或 3。' ;;
      esac
    done
    read -r -p '备注（可留空）: ' remark || return 1
    helper add "$CONF_FILE" "$candidate" "$listen" "$remote" "$protocol" "$remark" || return 1
    commit_config "$candidate" || return 1
    log "已添加节点：$listen -> $remote（协议=$protocol_name）"
    confirm '继续添加下一个节点吗？' || break
  done
  cleanup_workspace
}

delete_endpoints_interactive() {
  local count selection indices
  ensure_config || return 1
  count=$(helper count "$CONF_FILE") || return 1
  [[ $count != 0 ]] || { log '当前没有可删除的节点。'; return 0; }
  helper list "$CONF_FILE" || return 1
  read -r -p '删除索引（支持逗号和区间，如 1,3,5-7）: ' selection || return 1
  indices=$(helper select "$CONF_FILE" "$selection") || return 1
  confirm "确认删除节点 $indices？" || { log '已取消。'; return 0; }
  prepare_workspace || return 1
  helper delete "$CONF_FILE" "$TMP_DIR/config.toml" "$indices" || return 1
  commit_config "$TMP_DIR/config.toml" || return 1
  log "已删除节点：$indices"
  cleanup_workspace
}

uninstall_realm() {
  local purge=${1:-no} archived
  check_managed_paths || return 1
  if [[ -f $SERVICE_FILE ]] || systemctl is-active --quiet "$APP_NAME"; then
    systemctl stop "$APP_NAME" || return 1
    systemctl disable "$APP_NAME" >/dev/null || return 1
  fi
  rm -f -- "$SERVICE_FILE" "$BIN_PATH" || return 1
  systemctl daemon-reload || return 1
  systemctl reset-failed "$APP_NAME" >/dev/null 2>&1 || true
  if [[ $purge == yes && -d $CONF_DIR ]]; then
    archived=$(mktemp -d "${CONF_DIR}.bak.$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    mv -- "$CONF_DIR" "$archived/realm" || return 1
    log "配置及历史备份已移至：$archived/realm"
  else
    log "配置及历史备份保留在：$CONF_DIR"
  fi
  log '卸载完成。'
}

show_status() {
  printf '二进制：%s\n版本：%s\n配置：%s\n' "$BIN_PATH" "$(current_version)" "$CONF_FILE"
  printf '服务状态：'
  systemctl is-active "$APP_NAME" || true
  printf '开机启动：'
  systemctl is-enabled "$APP_NAME" || true
  if [[ -f $CONF_FILE ]]; then helper list "$CONF_FILE"; else log '暂无配置。'; fi
}

usage() {
  cat <<EOF
Realm 部署脚本 v3（Debian 12/13 + systemd）
用法：bash $0 [选项]
  无参数                     打开交互菜单
  --install                  安装/升级官方最新稳定版，保留配置和节点
  --install --reset-config   备份并清空节点，重置默认模板（明确执行即确认重置）
  --check-download           只验证官方最新包的下载、SHA-256 和运行兼容性
  --status                   查看版本、服务和节点
  --uninstall                卸载程序，保留配置
  --uninstall --purge         卸载程序，并将配置目录移到备份目录
  --help                     显示帮助

选项 1 保留配置；选项 2 清空节点。两者安装同一个官方最新版。
添加节点时可分别选择 TCP、UDP 或 TCP+UDP；每个节点独立生效。
缺少依赖时使用 apt-get 安装 curl、python3、python3-tomlkit 等 Debian 软件包。
下载自检不需要 systemd 或 root（依赖须已安装）。

可选环境变量：
  REALM_FORCE_IPV4=1
  REALM_GITHUB_PROXY=https://example.com/   优先使用指定代理，仍校验官方 SHA-256
  REALM_TMPDIR=/path/to/tmp                临时目录，默认遵守 TMPDIR
  REALM_MAXTIME=120                        单次下载最长秒数
EOF
}

main_menu() {
  local option uninstall_option
  while true; do
    printf '\n%s\n' '==== Realm 管理 v3 ====' \
      '1) 安装 / 升级 / 重装官方最新稳定版（保留配置和节点）【推荐】' \
      '2) 安装 / 升级并重置配置（备份旧配置，清空节点）' \
      '3) 卸载' '4) 查看状态与节点' '5) 添加转发节点（TCP / UDP / TCP+UDP）' '6) 删除 / 批量删除转发节点' 'q) 退出'
    read -r -p '请选择: ' option || return 0
    case "$option" in
      1) install_or_upgrade no || warn '安装未完成，请查看上方错误。' ;;
      2)
        if confirm '此操作会清空全部节点并停止转发（旧配置会备份），确认重置？'; then
          install_or_upgrade yes || warn '安装未完成，请查看上方错误。'
        fi ;;
      3)
        read -r -p '卸载：1 保留配置，2 将配置移到备份目录（默认 1）: ' uninstall_option || return 0
        case "${uninstall_option:-1}" in
          1) uninstall_realm no || warn '卸载未完成。' ;;
          2) uninstall_realm yes || warn '卸载未完成。' ;;
          *) warn '无效选择，已取消。' ;;
        esac ;;
      4) show_status || warn '读取状态失败。' ;;
      5) add_endpoint_interactive || warn '添加未完成，请查看上方错误。' ;;
      6) delete_endpoints_interactive || warn '删除未完成，请查看上方错误。' ;;
      q|Q) return 0 ;;
      *) warn '无效选择。' ;;
    esac
    cleanup_workspace || true
  done
}

main() {
  local mode=menu argument=${1:-}
  case "$argument" in
    -h|--help) [[ $# == 1 ]] || return 2; usage; return 0 ;;
    '') [[ $# == 0 ]] || return 2 ;;
    --check-download|--status) [[ $# == 1 ]] || { err '此选项不接受其他参数。'; return 2; }; mode=$argument ;;
    --install)
      [[ $# == 1 || ( $# == 2 && $2 == --reset-config ) ]] || { err '安装参数无效。'; return 2; }
      mode=$argument ;;
    --uninstall)
      [[ $# == 1 || ( $# == 2 && $2 == --purge ) ]] || { err '卸载参数无效。'; return 2; }
      mode=$argument ;;
    *) err "未知选项：$argument"; usage; return 2 ;;
  esac
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  [[ $(uname -s) == Linux ]] || { err '仅支持 Linux。'; return 1; }
  if [[ $mode == --check-download ]]; then
    ensure_cmds download || return 1
    prepare_workspace || return 1
    fetch_binary || return 1
    log '下载及运行自检通过，未安装系统服务或替换配置。'
    return 0
  fi
  [[ $EUID == 0 ]] || { err '请使用 root 运行：sudo bash realm_v3.sh'; return 1; }
  [[ -d /run/systemd/system ]] || { err '当前系统未由 systemd 管理。'; return 1; }
  ensure_cmds || return 1
  mkdir -p /run/lock || return 1
  exec 9>/run/lock/realm-v3.lock
  flock -n 9 || { err '另一个 realm_v3.sh 正在运行。'; return 1; }
  case "$mode" in
    menu) main_menu ;;
    --install) install_or_upgrade "$( [[ $# == 2 ]] && printf yes || printf no )" ;;
    --uninstall) uninstall_realm "$( [[ $# == 2 ]] && printf yes || printf no )" ;;
    --status) show_status ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

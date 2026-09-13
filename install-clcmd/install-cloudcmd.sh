#!/usr/bin/env bash
# Cloud Commander installer for Debian 12/13. Run with bash, not sh.
# The installer never removes or recursively changes permissions of media directories.

INSTALL_DIR=/opt/clcmd
SERVICE_NAME=cloudcmd.service
SERVICE_FILE=/etc/systemd/system/cloudcmd.service
LOCK_FILE=/run/cloudcmd-installer.lock
SCHEMA=cloudcmd-installer-v1
MODE=install
ROOT_SET=0
PORT_SET=0
MEDIA_ROOT=''
PANEL_PORT=5269
LOGIN_NAME='admin'
NEW_PASSWORD=''
CANDIDATE=''
PROBE_PID=''
PROBE_MARKER=''
SUCCESS=0
OLD_RELEASE=''
OLD_PREVIOUS=''
NODE_ARCH=''

log() { printf '[Cloud Commander] %s\n' "$*"; }
warn() { printf '[注意] %s\n' "$*" >&2; }
die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Cloud Commander 一键安装 / 升级（Debian 12/13，amd64/arm64）

  sudo bash install-cloudcmd.sh                     安装或升级，首次交互设置
  sudo bash install-cloudcmd.sh --root '/data/媒体库' 显式设置 / 修改媒体库
  sudo bash install-cloudcmd.sh --port 5269          显式设置 / 修改端口
  sudo bash install-cloudcmd.sh --check              只检查已安装服务
  bash install-cloudcmd.sh --help

固定安装位置 /opt/clcmd；root 运行；首次默认端口 5269；默认启用认证。
首次必须输入媒体库绝对路径、用户名和密码；目录不存在时自动创建。
重复运行保留凭据与设置，仅 --root / --port 显式修改相应设置。
密码不会出现在命令行、完成提示或日志中。没有终端时不能首次交互安装。
提供 HTTP 服务；HTTPS、域名及防火墙由 VPS 现有配置负责。
USAGE
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --root)
                (( $# >= 2 )) && [[ -n $2 ]] || die '--root 缺少目录。'
                (( ROOT_SET == 0 )) || die '--root 不能重复。'
                MEDIA_ROOT=$2; ROOT_SET=1; shift 2 ;;
            --port)
                (( $# >= 2 )) && [[ -n $2 ]] || die '--port 缺少端口。'
                (( PORT_SET == 0 )) || die '--port 不能重复。'
                PANEL_PORT=$2; PORT_SET=1; shift 2 ;;
            --check) MODE=check; shift ;;
            --help|-h) usage; exit 0 ;;
            *) die "未知参数：$1（使用 --help 查看用法）。" ;;
        esac
    done
    [[ $MODE != check ]] || (( ROOT_SET == 0 && PORT_SET == 0 )) || die '--check 不能同时修改目录或端口。'
    validate_port "$PANEL_PORT"
}

validate_port() {
    if [[ ! $1 =~ ^[0-9]{1,5}$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        die '端口必须是 1–65535 的整数。'
    fi
}

check_platform() {
    (( EUID == 0 )) || die '请以 root 执行：sudo bash install-cloudcmd.sh'
    [[ -r /etc/os-release ]] || die '无法读取 /etc/os-release。'
    local ID='' VERSION_ID=''
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ $ID == debian && ( $VERSION_ID == 12 || $VERSION_ID == 13 ) ]] || die '仅支持 Debian 12/13。'
    case "$(uname -m)" in
        x86_64) NODE_ARCH=x64 ;;
        aarch64|arm64) NODE_ARCH=arm64 ;;
        *) die '仅支持 amd64 / arm64。' ;;
    esac
    command -v systemctl >/dev/null && command -v systemd-analyze >/dev/null && [[ -d /run/systemd/system ]] || die '需要由 systemd 管理的 Debian VPS。'
    systemctl show --property=Version --value >/dev/null || die '无法连接 systemd。'
}

secure_path() {
    local target=$1 owner mode
    [[ ! -L $target ]] || die "管理路径不能是符号链接：$target"
    owner=$(stat -c '%u' -- "$target") || die "无法检查所有者：$target"
    mode=$(stat -c '%a' -- "$target") || die "无法检查权限：$target"
    if [[ $owner != 0 ]] || (( (8#$mode & 0022) != 0 )); then
        die "管理路径必须由 root 所有且不可被组或其他用户写入：$target"
    fi
}

inspect_installation() {
    if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
        [[ -d $INSTALL_DIR && ! -L $INSTALL_DIR ]] || die "$INSTALL_DIR 必须是实际目录。"
        secure_path "$INSTALL_DIR"
        if [[ -f $INSTALL_DIR/.managed-by && ! -L $INSTALL_DIR/.managed-by ]]; then
            [[ $(< "$INSTALL_DIR/.managed-by") == "$SCHEMA" ]] || die '安装标记不匹配，拒绝覆盖。'
            secure_path "$INSTALL_DIR/.managed-by"
        else
            [[ -z $(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "$INSTALL_DIR 包含未知安装，拒绝覆盖。"
        fi
    fi
    if [[ -e $SERVICE_FILE || -L $SERVICE_FILE ]]; then
        [[ -f $SERVICE_FILE && ! -L $SERVICE_FILE ]] || die "$SERVICE_FILE 是特殊文件或符号链接，拒绝接管。"
        secure_path "$SERVICE_FILE"
        if [[ ! -f $INSTALL_DIR/.managed-by ]] || ! head -n 1 "$SERVICE_FILE" | grep -Fxq "# Managed by $SCHEMA"; then
            die '发现非本脚本管理的 cloudcmd.service，拒绝覆盖。'
        fi
    fi
    local fragment
    fragment=$(systemctl show "$SERVICE_NAME" --property=FragmentPath --value 2>/dev/null) || die '无法查询已有服务。'
    [[ -z $fragment || $fragment == "$SERVICE_FILE" ]] || die "存在其他 Cloud Commander 服务：$fragment"
    local dropins
    dropins=$(systemctl show "$SERVICE_NAME" --property=DropInPaths --value 2>/dev/null) || die '无法查询服务附加配置。'
    [[ -z $dropins ]] || die 'cloudcmd.service 存在额外 drop-in，请先移走或合并配置再运行安装器。'
}

ensure_dependencies() {
    local command_name package
    local -a packages=()
    for pair in curl:curl python3:python3 tar:tar xz:xz-utils ss:iproute2 flock:util-linux; do
        command_name=${pair%%:*}; package=${pair#*:}
        command -v "$command_name" >/dev/null || packages+=("$package")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    if (( ${#packages[@]} )); then
        [[ $MODE != check ]] || die "缺少检查依赖：${packages[*]}"
        log "安装缺失基础依赖：${packages[*]}"
        apt-get update || die 'apt-get update 失败。'
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" || die "依赖安装失败：${packages[*]}"
    fi
}

prepare_base() {
    # The lock lives in root-owned /run, not the potentially world-writable /run/lock.
    [[ ! -L $LOCK_FILE ]] || die '安装锁不能是符号链接。'
    exec {INSTALL_LOCK_FD}>"$LOCK_FILE"
    flock -n "$INSTALL_LOCK_FD" || die '另一个安装器正在运行。'
    inspect_installation
    mkdir -p -- "$INSTALL_DIR" || die '创建安装目录失败。'
    if [[ ! -e $INSTALL_DIR/.managed-by ]]; then
        printf '%s\n' "$SCHEMA" > "$INSTALL_DIR/.managed-by"
        chmod 600 "$INSTALL_DIR/.managed-by"
    fi
    local directory
    for directory in releases cache; do
        if [[ -e $INSTALL_DIR/$directory || -L $INSTALL_DIR/$directory ]]; then
            [[ -d $INSTALL_DIR/$directory ]] || die "管理目录被文件占用：$directory"
            secure_path "$INSTALL_DIR/$directory"
        else
            mkdir -m 700 -- "$INSTALL_DIR/$directory" || die "创建目录失败：$directory"
        fi
    done
}

validate_release_name() {
    [[ $1 =~ ^release\.[a-zA-Z0-9]+$ ]] || return 1
    [[ -d $INSTALL_DIR/releases/$1 && ! -L $INSTALL_DIR/releases/$1 ]] || return 1
    [[ -f $INSTALL_DIR/releases/$1/.cloudcmd-release && ! -L $INSTALL_DIR/releases/$1/.cloudcmd-release ]] || return 1
    [[ $(< "$INSTALL_DIR/releases/$1/.cloudcmd-release") == "$SCHEMA" ]]
}

read_link() {
    local name=$1 target
    if [[ ! -e $INSTALL_DIR/$name && ! -L $INSTALL_DIR/$name ]]; then
        return 0
    fi
    [[ -L $INSTALL_DIR/$name ]] || die "$name 应为安装器管理的链接。"
    target=$(readlink -- "$INSTALL_DIR/$name") || die "无法读取 $name。"
    if [[ $target != releases/* ]] || ! validate_release_name "${target#releases/}"; then
        die "$name 指向未知版本，拒绝覆盖。"
    fi
    printf '%s' "${target#releases/}"
}

set_link() {
    local name=$1 release=$2 temporary
    if [[ -z $release ]]; then
        [[ ! -e $INSTALL_DIR/$name && ! -L $INSTALL_DIR/$name ]] && return 0
        [[ -L $INSTALL_DIR/$name ]] || return 1
        rm -- "$INSTALL_DIR/$name"
        return
    fi
    validate_release_name "$release" || return 1
    temporary="$INSTALL_DIR/.$name.new.$$"
    ln -s -- "releases/$release" "$temporary" || return 1
    mv -Tf -- "$temporary" "$INSTALL_DIR/$name" || { rm -f -- "$temporary"; return 1; }
}

validate_config() {
    [[ -f $1 && ! -L $1 ]] || die '配置文件缺失或为符号链接。'
    secure_path "$1"
    python3 - "$1" <<'PY' || die '配置校验失败；请修复原配置，不会自动重置密码。'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        d = json.load(f)
    assert isinstance(d, dict)
    assert isinstance(d.get('root'), str) and d['root'].startswith('/')
    assert not any(ord(c) < 32 or ord(c) == 127 for c in d['root'])
    assert type(d.get('port')) is int and 1 <= d['port'] <= 65535
    assert d.get('auth') is True
    assert isinstance(d.get('username'), str) and d['username'] and ':' not in d['username']
    assert not any(ord(c) < 32 or ord(c) == 127 for c in d['username'])
    assert isinstance(d.get('password'), str) and d['password']
    assert isinstance(d.get('algo'), str) and d['algo']
except (ValueError, OSError, AssertionError, TypeError):
    print('配置必须是有效 JSON，含绝对路径、合法端口和已启用的认证凭据。', file=sys.stderr)
    sys.exit(1)
PY
}

json_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]], end="")' "$1" "$2"
}

open_prompt() {
    if [[ -z ${PROMPT_FD:-} ]]; then
        { exec {PROMPT_FD}<> /dev/tty; } 2>/dev/null || die '需要交互终端输入媒体库和凭据，请在 SSH 终端直接运行脚本。'
    fi
}

prompt_root() {
    open_prompt
    while [[ -z $MEDIA_ROOT ]]; do
        printf '请输入媒体库绝对路径（无默认值）：' >&"$PROMPT_FD"
        IFS= read -r MEDIA_ROOT <&"$PROMPT_FD" || die '输入已结束，安装取消。'
    done
}

prompt_credentials() {
    local confirmation=''
    open_prompt
    printf '登录用户名 [admin]：' >&"$PROMPT_FD"
    IFS= read -r LOGIN_NAME <&"$PROMPT_FD" || die '输入已结束，安装取消。'
    LOGIN_NAME=${LOGIN_NAME:-admin}
    [[ $LOGIN_NAME != *:* && ! $LOGIN_NAME =~ [[:cntrl:]] ]] || die '用户名不能包含冒号或控制字符。'
    while :; do
        printf '登录密码：' >&"$PROMPT_FD"
        IFS= read -r -s NEW_PASSWORD <&"$PROMPT_FD" || die '输入已结束，安装取消。'
        printf '\n再次输入密码：' >&"$PROMPT_FD"
        IFS= read -r -s confirmation <&"$PROMPT_FD" || die '输入已结束，安装取消。'
        printf '\n' >&"$PROMPT_FD"
        if [[ -n $NEW_PASSWORD && $NEW_PASSWORD == "$confirmation" ]]; then break; fi
        printf '密码不能为空且两次必须相同，请重新输入。\n' >&"$PROMPT_FD"
    done
    unset confirmation
}

select_settings() {
    local config=''
    OLD_RELEASE=$(read_link current)
    OLD_PREVIOUS=$(read_link previous)
    if [[ -n $OLD_RELEASE ]]; then
        config="$INSTALL_DIR/releases/$OLD_RELEASE/home/.cloudcmd.json"
        validate_config "$config"
        (( ROOT_SET )) || MEDIA_ROOT=$(json_field "$config" root)
        (( PORT_SET )) || PANEL_PORT=$(json_field "$config" port)
        # An explicit --root/--port on an upgrade is applied to the new
        # release only; the old release remains an untouched rollback copy.
    else
        [[ ! -e $SERVICE_FILE ]] || die '存在服务但没有当前版本；请先检查安装目录。'
        (( ROOT_SET )) || prompt_root
        prompt_credentials
    fi
    validate_port "$PANEL_PORT"
    PANEL_PORT=$((10#$PANEL_PORT))
}

normalize_media_root() {
    [[ $MEDIA_ROOT == /* && ! $MEDIA_ROOT =~ [[:cntrl:]] ]] || die '媒体库必须是非空绝对路径，且不能包含控制字符。'
    MEDIA_ROOT=$(realpath -m -- "$MEDIA_ROOT") || die '媒体库路径无法规范化。'
    [[ $MEDIA_ROOT != "$INSTALL_DIR" && $MEDIA_ROOT != "$INSTALL_DIR/"* ]] || die '媒体库不能位于 /opt/clcmd 安装器管理目录内。'
    [[ ! -e $MEDIA_ROOT || -d $MEDIA_ROOT ]] || die '媒体库路径已存在但不是目录。'
}

ensure_media_root() {
    normalize_media_root
    if [[ ! -d $MEDIA_ROOT ]]; then
        (umask 022; mkdir -p -- "$MEDIA_ROOT") || die '创建媒体库失败。'
    fi
    [[ -d $MEDIA_ROOT && -r $MEDIA_ROOT && -x $MEDIA_ROOT ]] || die '媒体库目录不可读取或访问。'
}

listeners() { ss -H -ltnp "( sport = :$1 )"; }

listeners_match_pid() {
    python3 -c 'import re,sys; s=sys.stdin.read(); p=re.findall(r"pid=(\d+)",s); sys.exit(0 if p and set(p)=={sys.argv[1]} and all("pid=" in line for line in s.splitlines()) else 1)' "$1"
}

check_port_available() {
    local output pid
    output=$(listeners "$PANEL_PORT") || die '无法查询端口占用。'
    [[ -n $output ]] || return 0
    pid=$(systemctl show "$SERVICE_NAME" --property=MainPID --value) || die '无法查询当前服务 PID。'
    if [[ -n $OLD_RELEASE && $pid =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$output" | listeners_match_pid "$pid"; then
        return 0
    fi
    die "端口 $PANEL_PORT 已被其他进程占用；请释放端口或使用 --port。"
}

download_https() {
    local url=$1 destination=$2 temporary
    temporary="$destination.partial"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 240 --output "$temporary" "$url" || return 1
    mv -f -- "$temporary" "$destination"
}

create_candidate() {
    CANDIDATE=$(mktemp -d "$INSTALL_DIR/releases/release.XXXXXXXX") || die '无法创建候选目录。'
    printf '%s\n' "$SCHEMA" > "$CANDIDATE/.cloudcmd-release"
    mkdir -m 700 -- "$CANDIDATE/downloads" "$CANDIDATE/runtime" "$CANDIDATE/app" "$CANDIDATE/home" "$CANDIDATE/unit"
}

install_candidate() {
    local node_version package_version archive
    log '查询 Cloud Commander 最新稳定版和 Node.js 最新 LTS。'
    download_https https://registry.npmjs.org/cloudcmd/latest "$CANDIDATE/downloads/cloudcmd.json" || die '获取 npm latest 失败。'
    download_https https://nodejs.org/dist/index.json "$CANDIDATE/downloads/node-index.json" || die '获取 Node.js LTS 列表失败。'
    python3 - "$CANDIDATE" "$NODE_ARCH" <<'PY' || die '版本元数据无效或没有对应架构的 LTS。'
import json, pathlib, re, sys
p=pathlib.Path(sys.argv[1]); arch=sys.argv[2]
package=json.loads((p/'downloads/cloudcmd.json').read_text())
assert package['name']=='cloudcmd' and re.fullmatch(r'\d+\.\d+\.\d+', package['version'])
rows=json.loads((p/'downloads/node-index.json').read_text())
rows=[r for r in rows if r.get('lts') and re.fullmatch(r'v\d+\.\d+\.\d+',r['version']) and 'linux-'+arch in r['files']]
node=max(rows,key=lambda r:tuple(map(int,r['version'][1:].split('.'))))
(p/'versions.json').write_text(json.dumps({'cloudcmd':package['version'],'node':node['version'],'nodeEngine':package.get('engines',{}).get('node','')}))
(p/'app/package.json').write_text(json.dumps({'name':'clcmd-local-install','version':'1.0.0','private':True,'dependencies':{'cloudcmd':package['version']}},indent=2)+'\n')
PY
    node_version=$(json_field "$CANDIDATE/versions.json" node)
    package_version=$(json_field "$CANDIDATE/versions.json" cloudcmd)
    archive="node-$node_version-linux-$NODE_ARCH.tar.xz"
    log "准备 Cloud Commander $package_version / Node.js $node_version。"
    download_https "https://nodejs.org/dist/$node_version/$archive" "$CANDIDATE/downloads/$archive" || die 'Node.js 下载失败。'
    download_https "https://nodejs.org/dist/$node_version/SHASUMS256.txt" "$CANDIDATE/downloads/SHASUMS256.txt" || die 'Node.js 校验文件下载失败。'
    python3 - "$CANDIDATE/downloads" "$archive" <<'PY' || die 'Node.js SHA-256 校验失败。'
import hashlib, pathlib, re, sys
p=pathlib.Path(sys.argv[1]); name=sys.argv[2]
matches=[line.split()[0] for line in (p/'SHASUMS256.txt').read_text().splitlines() if len(line.split())==2 and line.split()[1]==name]
assert len(matches)==1 and re.fullmatch(r'[0-9a-f]{64}',matches[0])
h=hashlib.sha256()
with (p/name).open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
assert h.hexdigest()==matches[0]
PY
    tar -xJf "$CANDIDATE/downloads/$archive" --strip-components=1 --no-same-owner -C "$CANDIDATE/runtime" || die 'Node.js 解压失败。'
    "$CANDIDATE/runtime/bin/node" --version || die 'Node.js 无法在本机运行，请检查系统库兼容性。'
    # npm rejects using the same path for its user and global config files.
    # Keep both files inside the candidate so host-wide npm settings cannot
    # change the resolved dependency set.
    : > "$CANDIDATE/home/npmrc"
    : > "$CANDIDATE/home/globalnpmrc"
    chmod 600 "$CANDIDATE/home/npmrc" "$CANDIDATE/home/globalnpmrc"
    env -u NODE_OPTIONS -u NODE_PATH \
        PATH="$CANDIDATE/runtime/bin:$PATH" NODE_ENV=production \
        NPM_CONFIG_USERCONFIG="$CANDIDATE/home/npmrc" \
        NPM_CONFIG_GLOBALCONFIG="$CANDIDATE/home/globalnpmrc" \
        NPM_CONFIG_CACHE="$INSTALL_DIR/cache/npm" NPM_CONFIG_REGISTRY=https://registry.npmjs.org \
        "$CANDIDATE/runtime/bin/node" "$CANDIDATE/runtime/lib/node_modules/npm/bin/npm-cli.js" \
        install --prefix "$CANDIDATE/app" --omit=dev --engine-strict --ignore-scripts=false --no-audit --no-fund || die 'npm 安装失败；未切换当前版本。请查看上方依赖或 Node.js 兼容性错误。'
    local actual
    actual=$(env -i HOME="$CANDIDATE/home" PATH="$CANDIDATE/runtime/bin:/usr/bin:/bin" \
        "$CANDIDATE/runtime/bin/node" "$CANDIDATE/app/node_modules/cloudcmd/bin/cloudcmd.js" --version) || die 'Cloud Commander 无法执行。'
    [[ $actual == "v$package_version" && -s $CANDIDATE/app/node_modules/cloudcmd/dist/index.html && -s $CANDIDATE/app/package-lock.json ]] || die '安装后的版本或发布资产不完整。'
    rm -rf -- "$CANDIDATE/downloads"
}

# stdin is only the new plaintext password (empty for an upgrade). No secret argv/env.
write_config() {
    local source_config=${1:-}
    "$CANDIDATE/runtime/bin/node" -e '
const fs = require("node:fs");
const {createRequire} = require("node:module");
const [release, oldFile, media, port, username] = process.argv.slice(1);
const req = createRequire(release + "/app/node_modules/cloudcmd/package.json");
const defaults = req("./json/config.json");
const old = oldFile ? JSON.parse(fs.readFileSync(oldFile, "utf8")) : {};
const password = fs.readFileSync(0, "utf8");
const config = {...defaults, ...old, root:media, port:Number(port), ip:"0.0.0.0", auth:true, open:false, configAuth:false, configPort:false};
if (!oldFile) config.username = username;
if (password) config.password = req("criton")(password, config.algo);
if (!config.username || !config.password || typeof config.password !== "string") throw new Error("Missing credentials");
const target = release + "/home/.cloudcmd.json";
fs.writeFileSync(target + ".tmp", JSON.stringify(config, null, 2) + "\n", {mode:0o600});
fs.renameSync(target + ".tmp", target);
' "$CANDIDATE" "$source_config" "$MEDIA_ROOT" "$PANEL_PORT" "$LOGIN_NAME"
}

stop_probe() {
    if [[ -n $PROBE_PID ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        local i
        for ((i=0; i<20; i++)); do
            kill -0 "$PROBE_PID" 2>/dev/null || break
            sleep 0.1
        done
        kill -TERM "$PROBE_PID" 2>/dev/null || true
        wait "$PROBE_PID" 2>/dev/null || true
        PROBE_PID=''
    fi
    if [[ -n $PROBE_MARKER ]]; then
        rm -f -- "$PROBE_MARKER" 2>/dev/null || true
        PROBE_MARKER=''
    fi
}

probe_candidate() {
    local probe="$CANDIDATE/.probe" port='' deadline marker_name marker_arg=''
    mkdir -m 700 -- "$probe" || die '无法创建候选检查目录。'
    # A temporary marker lets the HTTP check prove that the configured root,
    # rather than the install directory or the process cwd, is listed. On a
    # deliberately read-only media directory we retain the structural API
    # check below instead of modifying that directory.
    marker_name=".cloudcmd-installer-probe.$$"
    if [[ ! -e "$MEDIA_ROOT/$marker_name" && ! -L "$MEDIA_ROOT/$marker_name" ]] &&
       ( umask 077; : > "$MEDIA_ROOT/$marker_name" ) 2>/dev/null; then
        PROBE_MARKER="$MEDIA_ROOT/$marker_name"
        marker_arg=$marker_name
    fi
    "$CANDIDATE/runtime/bin/node" -e '
const fs=require("node:fs"), crypto=require("node:crypto"), {createRequire}=require("node:module");
const r=process.argv[1];
const req=createRequire(r+"/app/node_modules/cloudcmd/package.json");
const config=JSON.parse(fs.readFileSync(r+"/home/.cloudcmd.json","utf8"));
const credentials={username:"installer-check", password:crypto.randomBytes(32).toString("hex")};
Object.assign(config,{...credentials,password:req("criton")(credentials.password,config.algo),auth:true,ip:"127.0.0.1",port:0,open:false,log:true,import:false,export:false,importListen:false,prefix:"",prefixSocket:""});
fs.writeFileSync(r+"/.probe/.cloudcmd.json",JSON.stringify(config),{mode:0o600});
fs.writeFileSync(r+"/.probe/credentials.json",JSON.stringify(credentials),{mode:0o600});
    ' "$CANDIDATE" || die '生成候选检查配置失败。'
    env -i HOME="$probe" PATH="$CANDIDATE/runtime/bin:/usr/sbin:/usr/bin:/sbin:/bin" NODE_ENV=production LANG=C.UTF-8 \
        "$CANDIDATE/runtime/bin/node" "$CANDIDATE/app/node_modules/cloudcmd/bin/cloudcmd.js" --auth --no-open \
        >"$probe/server.log" 2>&1 &
    PROBE_PID=$!
    deadline=$((SECONDS+30))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$PROBE_PID" 2>/dev/null; then
            tail -n 20 "$probe/server.log" >&2
            die '候选服务在启动检查中退出。'
        fi
        port=$(sed -nE 's@^url: http://127\.0\.0\.1:([0-9]+)/$@\1@p' "$probe/server.log" | head -n 1)
        [[ -z $port ]] || break
        sleep 0.2
    done
    [[ $port =~ ^[0-9]+$ ]] || die '候选服务启动超时。'
    "$CANDIDATE/runtime/bin/node" -e '
const fs=require("node:fs"), http=require("node:http");
const [r,port,root,marker]=process.argv.slice(1), credentials=JSON.parse(fs.readFileSync(r+"/.probe/credentials.json","utf8"));
function get(path,password) { return new Promise((resolve,reject)=>{
  const headers=password===undefined?{}:{Authorization:"Basic "+Buffer.from(credentials.username+":"+password).toString("base64")};
  const request=http.get({hostname:"127.0.0.1",port:Number(port),path,headers},response=>{
    let body=""; response.setEncoding("utf8"); response.on("data",chunk=>body+=chunk); response.on("end",()=>resolve({status:response.statusCode,body}));
    response.on("error",reject);
  }); request.setTimeout(15000,()=>request.destroy(new Error("HTTP timeout"))); request.on("error",reject);
}); }
(async()=>{
  for (const [password,status] of [[undefined,401],[credentials.password+"wrong",401],[credentials.password,200]]) {
    const response=await get("/",password); if(response.status!==status) throw new Error("Unexpected homepage HTTP status: "+response.status);
  }
  const response=await get("/api/v1/config",credentials.password);
  if(response.status!==200) throw new Error("Cannot read effective config");
  const config=JSON.parse(response.body);
  if(config.root!==root || !config.auth || config.port!==0) throw new Error("Effective config mismatch");
  const listing=await get("/api/v1/fs/?sort=name",credentials.password);
  if(listing.status!==200) throw new Error("Cannot list configured media root");
  const files=JSON.parse(listing.body);
  if(files.path!=="/" || !Array.isArray(files.files)) throw new Error("Media root listing is not a directory response");
  if(marker && !files.files.some(file=>file.name===marker)) throw new Error("Media root marker is missing from homepage listing");
})().catch(error=>{console.error(error.message);process.exitCode=1;});
' "$CANDIDATE" "$port" "$MEDIA_ROOT" "$marker_arg" || die '候选服务认证、首页或配置检查失败。'
    stop_probe
    rm -rf -- "$probe"
    log '候选版本认证及媒体库首页检查通过。'
}

write_unit() {
    local destination=$1 runtime_root=$2
    cat > "$destination" <<UNIT
# Managed by $SCHEMA
[Unit]
Description=Cloud Commander file manager
After=network.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$INSTALL_DIR
Environment=HOME=$runtime_root/home
Environment=PATH=$runtime_root/runtime/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_ENV=production
ExecStart=$runtime_root/runtime/bin/node $runtime_root/app/node_modules/cloudcmd/bin/cloudcmd.js --auth --no-open
Restart=on-failure
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=15
NoNewPrivileges=true
UMask=0022

[Install]
WantedBy=multi-user.target
UNIT
}

begin_transaction() {
    local active=0 enabled=disabled unit=0 temp
    systemctl is-active --quiet "$SERVICE_NAME" && active=1
    if [[ -f $SERVICE_FILE ]]; then
        unit=1
        enabled=$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null) || true
        case "$enabled" in enabled|enabled-runtime|disabled) ;; *) die "不支持自动接管当前启用状态：$enabled" ;; esac
    fi
    temp=$(mktemp -d "$INSTALL_DIR/.transaction.new.XXXXXXXX") || die '无法准备事务记录。'
    if (( unit )); then cp -a -- "$SERVICE_FILE" "$temp/unit.backup" || die '无法备份服务配置。'; fi
    python3 - "$temp" "$OLD_RELEASE" "$OLD_PREVIOUS" "${CANDIDATE##*/}" "$active" "$enabled" "$unit" "$SCHEMA" <<'PY' || die '无法保存事务记录。'
import json, os, pathlib, sys
p=pathlib.Path(sys.argv[1]); values=sys.argv[2:]
d=dict(zip(('old','previous','candidate','active','enabled','unit','schema'),values))
with (p/'state.json').open('w') as f:
    json.dump(d,f); f.flush(); os.fsync(f.fileno())
PY
    mv -T -- "$temp" "$INSTALL_DIR/.transaction" || die '无法启用事务记录。'
}

remove_release() {
    local name=$1 current previous
    validate_release_name "$name" || return 1
    current=$(read_link current); previous=$(read_link previous)
    [[ $name != "$current" && $name != "$previous" ]] || return 1
    rm -rf -- "$INSTALL_DIR/releases/$name"
}

rollback_transaction() {
    local txn="$INSTALL_DIR/.transaction" old previous candidate active enabled unit
    [[ -d $txn && ! -L $txn ]] || return 1
    python3 - "$txn/state.json" "$SCHEMA" <<'PY' || return 1
import json,re,sys
d=json.load(open(sys.argv[1]))
assert d['schema']==sys.argv[2]
for key in ('old','previous','candidate'):
    assert (not d[key] and key!='candidate') or re.fullmatch(r'release\.[a-zA-Z0-9]+',d[key])
assert d['active'] in ('0','1') and d['unit'] in ('0','1')
assert d['enabled'] in ('enabled','enabled-runtime','disabled')
PY
    old=$(json_field "$txn/state.json" old) || return 1
    previous=$(json_field "$txn/state.json" previous) || return 1
    candidate=$(json_field "$txn/state.json" candidate) || return 1
    active=$(json_field "$txn/state.json" active) || return 1
    enabled=$(json_field "$txn/state.json" enabled) || return 1
    unit=$(json_field "$txn/state.json" unit) || return 1
    [[ -z $old ]] || validate_release_name "$old" || return 1
    [[ -z $previous ]] || validate_release_name "$previous" || return 1
    validate_release_name "$candidate" || return 1
    if [[ -f $txn/committed ]]; then
        rm -rf -- "$txn"
        return 0
    fi
    warn '恢复升级前的版本、配置和服务状态。'
    if [[ -f $SERVICE_FILE ]]; then
        systemctl stop "$SERVICE_NAME" || return 1
        systemctl disable "$SERVICE_NAME" >/dev/null || return 1
    fi
    set_link current "$old" || return 1
    set_link previous "$previous" || return 1
    if [[ $unit == 1 ]]; then
        [[ -f $txn/unit.backup && ! -L $txn/unit.backup ]] || return 1
        install -m 644 -- "$txn/unit.backup" "$SERVICE_FILE" || return 1
    else
        rm -f -- "$SERVICE_FILE" || return 1
    fi
    systemctl daemon-reload || return 1
    case "$enabled" in
        enabled) systemctl enable "$SERVICE_NAME" >/dev/null || return 1 ;;
        enabled-runtime) systemctl enable --runtime "$SERVICE_NAME" >/dev/null || return 1 ;;
    esac
    if [[ $active == 1 ]]; then systemctl restart "$SERVICE_NAME" || return 1; fi
    rm -rf -- "$txn" || return 1
    remove_release "$candidate" || return 1
    log '已恢复原安装。'
}

service_healthy() {
    local release=$1 port=$2 pid exe output status
    systemctl is-active --quiet "$SERVICE_NAME" || return 1
    pid=$(systemctl show "$SERVICE_NAME" --property=MainPID --value) || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    exe=$(readlink -f "/proc/$pid/exe") || return 1
    [[ $exe == "$INSTALL_DIR/releases/$release/runtime/bin/node" ]] || return 1
    output=$(listeners "$port") || return 1
    printf '%s\n' "$output" | listeners_match_pid "$pid" || return 1
    status=$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 2 --max-time 5 "http://127.0.0.1:$port/") || return 1
    [[ $status == 401 ]]
}

wait_service_healthy() {
    local release=$1 deadline=$((SECONDS+40)) hits=0
    while (( SECONDS < deadline )); do
        if service_healthy "$release" "$PANEL_PORT"; then
            hits=$((hits+1))
            (( hits >= 3 )) && return 0
        else
            hits=0
        fi
        sleep 1
    done
    return 1
}

activate_candidate() {
    local source_config='' new=${CANDIDATE##*/} before='' after='' unit_tmp
    if [[ -n $OLD_RELEASE ]]; then
        source_config="$INSTALL_DIR/releases/$OLD_RELEASE/home/.cloudcmd.json"
        before=$(sha256sum "$source_config")
    fi
    # Always build the candidate from the selected old config. The old file
    # is never modified before the candidate has passed its probe.
    printf '%s' "$NEW_PASSWORD" | write_config "$source_config" || die '配置生成失败。'
    unset NEW_PASSWORD
    probe_candidate
    write_unit "$CANDIDATE/unit/$SERVICE_NAME" "$CANDIDATE"
    systemd-analyze verify "$CANDIDATE/unit/$SERVICE_NAME" || die 'systemd 单元校验失败。'
    begin_transaction
    if [[ -n $OLD_RELEASE ]]; then
        systemctl stop "$SERVICE_NAME" || die '停止原服务失败。'
        # The file may have been changed by the web UI while the candidate
        # was being prepared. Re-copy it into the candidate, then re-probe;
        # never write the user's live config in place.
        validate_config "$source_config"
        after=$(sha256sum "$source_config")
        if [[ $before != "$after" ]]; then
            (( ROOT_SET )) || MEDIA_ROOT=$(json_field "$source_config" root)
            (( PORT_SET )) || PANEL_PORT=$(json_field "$source_config" port)
            validate_port "$PANEL_PORT"
            ensure_media_root
            write_config "$source_config" </dev/null || die '复制最新配置失败。'
            probe_candidate
        fi
    fi
    check_port_available
    set_link current "$new" || die '切换版本失败。'
    write_unit "$CANDIDATE/unit/$SERVICE_NAME" "$INSTALL_DIR/current"
    unit_tmp="$SERVICE_FILE.tmp.$$"
    install -m 644 -- "$CANDIDATE/unit/$SERVICE_NAME" "$unit_tmp" || die '服务文件写入失败。'
    mv -fT -- "$unit_tmp" "$SERVICE_FILE" || die '服务文件替换失败。'
    systemctl daemon-reload || die 'systemd daemon-reload 失败。'
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME" || die 'Cloud Commander 启动失败。'
    wait_service_healthy "$new" || die "服务或 HTTP 检查失败；请查看 journalctl -u $SERVICE_NAME。"
    systemctl enable "$SERVICE_NAME" >/dev/null || die '设置开机启动失败。'
    systemctl is-enabled --quiet "$SERVICE_NAME" || die '开机启动状态异常。'
    set_link previous "$OLD_RELEASE" || die '保存回滚链接失败。'
    printf 'committed\n' > "$INSTALL_DIR/.transaction/committed"
    SUCCESS=1
    rm -rf -- "$INSTALL_DIR/.transaction"
    # Keep the previous rollback copy. A later successful upgrade may clean
    # it after recording its own rollback target; never delete it twice.
    log "安装成功：Cloud Commander $(json_field "$CANDIDATE/versions.json" cloudcmd)"
    log "访问地址：http://<VPS-IP>:$PANEL_PORT/"
    log "媒体库：$MEDIA_ROOT"
    log "配置：$INSTALL_DIR/current/home/.cloudcmd.json"
    log "服务：systemctl status $SERVICE_NAME --no-pager"
}

check_installation() {
    [[ -f $INSTALL_DIR/.managed-by ]] || die '尚未安装。'
    [[ ! -e $INSTALL_DIR/.transaction ]] || die '存在未完成的安装事务，请重新运行安装器恢复。'
    local current config
    current=$(read_link current)
    [[ -n $current ]] || die '没有当前版本。'
    config="$INSTALL_DIR/releases/$current/home/.cloudcmd.json"
    validate_config "$config"
    MEDIA_ROOT=$(json_field "$config" root)
    PANEL_PORT=$(json_field "$config" port)
    normalize_media_root
    [[ -d $MEDIA_ROOT && -r $MEDIA_ROOT && -x $MEDIA_ROOT ]] || die '媒体库缺失或不可访问。'
    systemctl is-enabled --quiet "$SERVICE_NAME" || die '服务没有开机启用。'
    service_healthy "$current" "$PANEL_PORT" || die '服务、进程身份、端口或 HTTP 认证检查失败。'
    log "检查通过：端口 $PANEL_PORT；媒体库 $MEDIA_ROOT；服务已启用。"
}

on_exit() {
    local status=$?
    trap - EXIT ERR INT TERM
    set +e
    stop_probe
    unset NEW_PASSWORD
    if [[ -d $INSTALL_DIR/.transaction ]]; then
        if ! rollback_transaction; then
            warn "自动恢复失败，事务和版本已保留在 $INSTALL_DIR，请修复服务错误后重新运行安装器。"
            status=1
        fi
    elif (( SUCCESS == 0 )) && [[ -n $CANDIDATE ]]; then
        remove_release "${CANDIDATE##*/}" || true
    fi
    exit "$status"
}

main() {
    parse_args "$@"
    check_platform
    inspect_installation
    ensure_dependencies
    if [[ $MODE == check ]]; then
        check_installation
        return
    fi
    prepare_base
    if [[ -e $INSTALL_DIR/.transaction || -L $INSTALL_DIR/.transaction ]]; then
        rollback_transaction || die '上次安装事务无法恢复，已保留所有版本和事务记录。'
    fi
    select_settings
    ensure_media_root
    check_port_available
    create_candidate
    install_candidate
    activate_candidate
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set +x
    set -Eeuo pipefail
    umask 077
    trap 'printf "[错误] 安装器第 %s 行失败。\n" "$LINENO" >&2' ERR
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main "$@"
fi

#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/personal-google-browser"
readonly PROJECT_NAME="personal-google-browser"
readonly CONTAINER_NAME="google-browser"
readonly NETWORK_NAME="personal-google-browser-proxy"
readonly NPM_CONTAINER="npm"
readonly IMAGE="jlesage/firefox:latest"

ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
CONFIG_DIR="$INSTALL_DIR/firefox-config"
TEMP_ENV=""
TEMP_COMPOSE=""
FORCE=0
CREATED_CREDENTIALS=0
FIREFOX_USERNAME=""
FIREFOX_PASSWORD=""

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

cleanup() {
    if [[ -n "$TEMP_ENV" && -e "$TEMP_ENV" ]]; then
        rm -f -- "$TEMP_ENV"
    fi
    if [[ -n "$TEMP_COMPOSE" && -e "$TEMP_COMPOSE" ]]; then
        rm -f -- "$TEMP_COMPOSE"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
用法：install_google_search.sh [--force]

  默认       安装或更新服务，复用现有凭据和 Firefox 配置
  --force    完全重置 Firefox 容器、登录凭据和浏览器配置
EOF
}

case "${1:-}" in
    "") ;;
    --force)
        FORCE=1
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

[[ $EUID -eq 0 ]] || die "请使用 sudo 运行，例如 curl ... | sudo bash。"
[[ ! -L /opt/personal-google-browser ]] || die "$INSTALL_DIR 是符号链接；为保护目录外的数据，已停止。"

if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    die "安装需要交互式终端来设置登录凭据和确认操作。"
fi

command -v docker >/dev/null 2>&1 || die "未找到 Docker。请先安装并启动 Docker Engine。"
docker compose version >/dev/null 2>&1 || die "未找到 Docker Compose 插件。请安装 Docker Compose v2。"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon。请检查 Docker 是否正在运行。"

if ! npm_running=$(docker inspect --format '{{.State.Running}}' "$NPM_CONTAINER" 2>/dev/null); then
    die "未找到名为 npm 的 Nginx Proxy Manager 容器。"
fi
[[ $npm_running == true ]] || die "NPM 容器 npm 未运行。"

check_managed_container() {
    local project service
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER_NAME" 2>/dev/null || true)
        service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$CONTAINER_NAME" 2>/dev/null || true)
        [[ $project == "$PROJECT_NAME" && $service == firefox ]] || die "容器 $CONTAINER_NAME 已存在，但不属于本工具；为保护现有容器，已停止。"
    fi
}
check_managed_container

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    network_driver=$(docker network inspect --format '{{.Driver}}' "$NETWORK_NAME")
    [[ $network_driver == bridge ]] || die "Docker 网络 $NETWORK_NAME 已存在，但不是 bridge 网络。"
fi

if (( FORCE )); then
    printf '强制重置会删除 %s 下的 Firefox 配置、登录状态和凭据。\n' "$INSTALL_DIR" >&3
    printf '保留 NPM 容器及 Docker 网络。请输入 RESET 继续：' >&3
    IFS= read -r -u 3 confirmation || die "未读取到确认内容。"
    [[ $confirmation == RESET ]] || die "确认内容不匹配，未执行重置。"
    info "请输入新的 Firefox 网页登录凭据。"
elif [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" && -s "$ENV_FILE" ]] || die "$ENV_FILE 不是有效的普通凭据文件；使用 --force 重新设置。"
    chmod 600 "$ENV_FILE"
    info "复用现有登录凭据和 Firefox 配置。"
else
    info "首次安装，请设置 Firefox 网页登录凭据。"
fi

if (( FORCE )) || [[ ! -e "$ENV_FILE" ]]; then
    printf '登录用户名 [google]：' >&3
    IFS= read -r -u 3 FIREFOX_USERNAME || die "未读取到用户名。"
    FIREFOX_USERNAME=${FIREFOX_USERNAME:-google}
    [[ -n $FIREFOX_USERNAME && ! $FIREFOX_USERNAME =~ [[:cntrl:]] ]] || die "用户名不能为空或包含控制字符。"

    printf '登录密码（至少 8 位）：' >&3
    IFS= read -r -s -u 3 FIREFOX_PASSWORD || die "未读取到密码。"
    printf '\n' >&3
    [[ ${#FIREFOX_PASSWORD} -ge 8 ]] || die "密码至少需要 8 位。"
    [[ ! $FIREFOX_PASSWORD =~ [[:cntrl:]] ]] || die "密码不能包含控制字符。"

    printf '再次输入密码：' >&3
    IFS= read -r -s -u 3 password_confirmation || die "未读取到密码确认。"
    printf '\n' >&3
    [[ $FIREFOX_PASSWORD == "$password_confirmation" ]] || die "两次输入的密码不一致。"
    unset password_confirmation
    CREATED_CREDENTIALS=1
fi

umask 077
mkdir -p -- "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

if [[ -L "$CONFIG_DIR" ]]; then
    die "$CONFIG_DIR 是符号链接；为保护目录外的数据，已停止。"
fi
if [[ -e "$CONFIG_DIR" && ! -d "$CONFIG_DIR" ]]; then
    die "$CONFIG_DIR 已存在但不是目录。"
fi

if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
fi
if ! docker network inspect --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$NETWORK_NAME" | grep -Fxq "$NPM_CONTAINER"; then
    docker network connect "$NETWORK_NAME" "$NPM_CONTAINER"
fi
docker network inspect --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$NETWORK_NAME" | grep -Fxq "$NPM_CONTAINER" \
    || die "NPM 未能接入 Docker 网络 $NETWORK_NAME。"

if (( FORCE )); then
    if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        docker rm -f "$CONTAINER_NAME" >/dev/null
    fi
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf -- "$CONFIG_DIR"
    fi
    rm -f -- "$ENV_FILE"
fi

if (( CREATED_CREDENTIALS )); then
    dotenv_quote() {
        local value=$1
        value=${value//\'/\\\'}
        printf "'%s'" "$value"
    }

    TEMP_ENV=$(mktemp "$INSTALL_DIR/.env.XXXXXX")
    {
        printf 'FIREFOX_WEB_USERNAME=%s\n' "$(dotenv_quote "$FIREFOX_USERNAME")"
        printf 'FIREFOX_WEB_PASSWORD=%s\n' "$(dotenv_quote "$FIREFOX_PASSWORD")"
    } >"$TEMP_ENV"
    chmod 600 "$TEMP_ENV"
    mv -f -- "$TEMP_ENV" "$ENV_FILE"
    TEMP_ENV=""
    unset FIREFOX_PASSWORD
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
    mkdir -m 700 -- "$CONFIG_DIR"
fi

TEMP_COMPOSE=$(mktemp "$INSTALL_DIR/compose.yaml.XXXXXX")
cat >"$TEMP_COMPOSE" <<EOF
name: $PROJECT_NAME

services:
  firefox:
    image: $IMAGE
    container_name: $CONTAINER_NAME
    restart: unless-stopped
    shm_size: "1gb"
    environment:
      USER_ID: "1000"
      GROUP_ID: "1000"
      UMASK: "077"
      TZ: "Asia/Shanghai"
      FF_OPEN_URL: "https://www.google.com/"
      SECURE_CONNECTION: "1"
      WEB_AUTHENTICATION: "1"
      WEB_AUTHENTICATION_USERNAME: \${FIREFOX_WEB_USERNAME:?Credentials are missing from .env}
      WEB_AUTHENTICATION_PASSWORD: \${FIREFOX_WEB_PASSWORD:?Credentials are missing from .env}
      WEB_AUTHENTICATION_TOKEN_VALIDITY_TIME: "24"
      WEB_TERMINAL: "0"
      WEB_FILE_MANAGER: "0"
      WEB_NOTIFICATION: "0"
      WEB_HOST_CLIPBOARD_SYNC: "1"
      ENABLE_CJK_FONT: "1"
    volumes:
      - ./firefox-config:/config
    expose:
      - "5800"
    networks:
      npm-proxy:
        aliases:
          - google-browser

networks:
  npm-proxy:
    external: true
    name: $NETWORK_NAME
EOF
chmod 600 "$TEMP_COMPOSE"
mv -f -- "$TEMP_COMPOSE" "$COMPOSE_FILE"
TEMP_COMPOSE=""

compose=(docker compose --project-name "$PROJECT_NAME" --project-directory "$INSTALL_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
"${compose[@]}" config --quiet || die "Docker Compose 配置校验失败。"
"${compose[@]}" pull firefox
"${compose[@]}" up -d

if ! docker exec "$NPM_CONTAINER" nginx -t; then
    die "NPM 的 nginx -t 检查失败，未执行 reload。浏览器容器已经部署，请先修复 NPM 配置后再重跑脚本。"
fi
docker exec "$NPM_CONTAINER" nginx -s reload || die "NPM 配置检查通过，但 Nginx reload 失败。浏览器容器已经部署。"

info "部署完成。"
info "NPM 页面请手动设置：Scheme=https，Forward Hostname=google-browser，Forward Port=5800，并开启 Websockets Support。"
info "浏览器数据保存在 $CONFIG_DIR；登录凭据保存在权限为 600 的 $ENV_FILE。"
info "通过 sudo cat $ENV_FILE 可查看已保存的用户名和密码。"

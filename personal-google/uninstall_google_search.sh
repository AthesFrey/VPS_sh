#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_DIR="/opt/personal-google-browser"
readonly PROJECT_NAME="personal-google-browser"
readonly CONTAINER_NAME="google-browser"
readonly NETWORK_NAME="personal-google-browser-proxy"
readonly IMAGE="jlesage/firefox:latest"

die() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

[[ $EUID -eq 0 ]] || die "请使用 sudo 运行此脚本。"
command -v docker >/dev/null 2>&1 || die "未找到 Docker。"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon。"

[[ ! -L "$INSTALL_DIR" ]] || die "$INSTALL_DIR 是符号链接；为保护目录外的数据，已停止。"
if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    die "$INSTALL_DIR 存在但不是目录。"
fi
if [[ -d "$INSTALL_DIR" ]] && command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$INSTALL_DIR"; then
    die "$INSTALL_DIR 是挂载点；为保护挂载数据，已停止。"
fi

REMOVE_CONTAINER=0
if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    project=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER_NAME")
    service=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$CONTAINER_NAME")
    [[ $project == "$PROJECT_NAME" && $service == firefox ]] \
        || die "容器 $CONTAINER_NAME 不属于本工具；为保护现有容器，已停止。"
    REMOVE_CONTAINER=1
fi

if (( REMOVE_CONTAINER )); then
    docker rm -f "$CONTAINER_NAME" >/dev/null
    info "已停止并删除容器 $CONTAINER_NAME。"
else
    info "未发现容器 $CONTAINER_NAME。"
fi

if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf -- "$INSTALL_DIR"
    info "已删除 $INSTALL_DIR，包括凭据和 Firefox 浏览器数据。"
else
    info "未发现安装目录 $INSTALL_DIR。"
fi

if image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null); then
    image_users=$(docker ps -aq --filter "ancestor=$image_id")
    if [[ -n "$image_users" ]]; then
        info "其他容器仍引用 $IMAGE，保留镜像。"
    elif ! docker image rm "$IMAGE"; then
        info "镜像 $IMAGE 未能删除，已保留。"
    fi
fi

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    printf '\n当前 Docker 网络：\n'
    docker network ls

    network_driver=$(docker network inspect --format '{{.Driver}}' "$NETWORK_NAME")
    network_members=$(docker network inspect --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$NETWORK_NAME")
    printf '\n目标网络：%s（driver=%s）\n' "$NETWORK_NAME" "$network_driver"
    if [[ -n "$network_members" ]]; then
        printf '连接到目标网络的容器：\n%s' "$network_members"
    else
        printf '当前没有容器连接到目标网络。\n'
    fi

    if [[ "$network_driver" != bridge ]]; then
        info "目标网络不是 bridge 类型，保留该网络。"
    elif ! { exec 3<>/dev/tty; } 2>/dev/null; then
        info "没有交互式终端，保留目标网络。"
    else
        printf '\n删除该网络会断开上面列出的所有容器与此网络的连接。\n' >&3
        printf '输入完整网络名称 %s 确认删除；其他输入将保留网络：' "$NETWORK_NAME" >&3
        IFS= read -r -u 3 network_confirmation || network_confirmation=''
        if [[ "$network_confirmation" == "$NETWORK_NAME" ]]; then
            while IFS= read -r container_name; do
                [[ -n "$container_name" ]] || continue
                docker network disconnect --force "$NETWORK_NAME" "$container_name" \
                    || die "无法将容器 $container_name 从网络 $NETWORK_NAME 断开。"
            done <<<"$network_members"
            docker network rm "$NETWORK_NAME" >/dev/null
            info "已删除网络 $NETWORK_NAME。"
        else
            info "保留网络 $NETWORK_NAME。"
        fi
    fi
else
    info "未发现网络 $NETWORK_NAME。"
fi

info "卸载完成。NPM 容器、NPM 页面配置、证书和 DNS 均未修改。"

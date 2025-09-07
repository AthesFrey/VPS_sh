#!/usr/bin/env bash
# vnStat latest auto-install (source build) for Debian/Ubuntu
# - 自动探测最新版 (GitHub API 优先，humdi 站点兜底)
# - 自动探测外网网卡（不限 eth0）
# - 幂等：可反复执行，不会报错或重复创建
set -Eeuo pipefail

log() { printf "\033[1;32m[i]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }
trap 'err "发生错误：第 $LINENO 行，退出。"' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请以 root 运行（例如：sudo -i 后再执行）。"
    exit 1
  fi
}

# --- 检测最新版本与下载链接 ---
detect_latest() {
  local ver="" url="" json=""
  # 1) GitHub releases （优先，速度快且稳定）
  if command -v curl >/dev/null 2>&1; then
    json="$(curl -fsSL https://api.github.com/repos/vergoh/vnstat/releases/latest || true)"
  elif command -v wget >/dev/null 2>&1; then
    json="$(wget -qO- https://api.github.com/repos/vergoh/vnstat/releases/latest || true)"
  fi

  if [[ -n "${json}" ]]; then
    ver="$(printf '%s' "$json" | grep -m1 -Eo '"tag_name":[[:space:]]*"v[0-9.]+"' | grep -Eo '[0-9.]+' || true)"
    # 从 assets 里直接找 .tar.gz
    url="$(printf '%s' "$json" | grep -Eo '"browser_download_url":[[:space:]]*"[^"]+\.tar\.gz"' | head -1 | cut -d'"' -f4 || true)"
    if [[ -z "$url" && -n "$ver" ]]; then
      # 备用拼接（通常也可用）
      url="https://github.com/vergoh/vnStat/releases/download/v${ver}/vnstat-${ver}.tar.gz"
    fi
  fi

  # 2) 兜底：humdi 官方目录抓取（如 GitHub API 不可达）
  if [[ -z "$ver" || -z "$url" ]]; then
    warn "GitHub 获取失败，尝试 humdi.net 兜底 ..."
    local idx=""
    if command -v curl >/dev/null 2>&1; then
      idx="$(curl -fsSL https://humdi.net/vnstat/ || true)"
    else
      idx="$(wget -qO- https://humdi.net/vnstat/ || true)"
    fi
    if [[ -n "$idx" ]]; then
      ver="$(printf '%s' "$idx" \
        | grep -Eo 'vnstat-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz' \
        | sed -E 's/.*vnstat-([0-9]+\.[0-9]+(\.[0-9]+)?)\.tar\.gz/\1/' \
        | sort -V | tail -1 || true)"
      if [[ -n "$ver" ]]; then
        url="https://humdi.net/vnstat/vnstat-${ver}.tar.gz"
      fi
    fi
  fi

  if [[ -z "$ver" || -z "$url" ]]; then
    err "无法检测到最新版 vnStat 下载地址。"
    exit 1
  fi

  VN_VER="$ver"
  VN_URL="$url"
}

# --- 获取活动外网网卡 ---
detect_iface() {
  local iface=""
  # v4 默认路由优先
  iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  # 如无 v4 默认路由，尝试 v6
  if [[ -z "$iface" ]]; then
    iface="$(ip -o -6 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  fi
  # 再兜底：挑选 state UP 且非 lo/docker/veth/br/zt/tun/tap 的第一块
  if [[ -z "$iface" ]]; then
    iface="$(
      ip -o link show up 2>/dev/null \
      | awk -F': ' '{print $2}' \
      | grep -Ev '^(lo|docker0|br-|veth|tun|tap|zt|tailscale|vmnet|virbr|wg)' \
      | head -1 || true
    )"
  fi
  IFACE="$iface"  # 允许为空，后面用时判断
}

# --- 安装构建依赖 ---
install_deps() {
  log "安装编译依赖 ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget tar xz-utils \
    build-essential make sqlite3 libsqlite3-dev
}

# --- 下载 & 解压 ---
fetch_and_extract() {
  log "准备源码目录 /usr/src"
  install -d /usr/src
  cd /usr/src

  local tarball="vnstat-${VN_VER}.tar.gz"
  if [[ ! -f "$tarball" ]]; then
    log "下载：$VN_URL"
    if command -v curl >/dev/null 2>&1; then
      curl -fL "$VN_URL" -o "$tarball"
    else
      wget -O "$tarball" "$VN_URL"
    fi
  else
    log "已存在压缩包：$tarball（跳过下载）"
  fi

  # 解压（幂等）
  if [[ -d "vnstat-${VN_VER}" ]]; then
    log "源码目录已存在：vnstat-${VN_VER}（跳过解压）"
  else
    tar -xzf "$tarball"
  fi
  cd "vnstat-${VN_VER}"
}

# --- 若已是该版本则跳过编译安装 ---
check_installed_same_version() {
  if command -v vnstat >/dev/null 2>&1; then
    local cur=""
    cur="$(vnstat --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
    if [[ "$cur" == "$VN_VER" ]]; then
      warn "当前已安装 vnStat $cur（与最新 $VN_VER 一致），跳过编译安装。"
      return 0
    fi
  fi
  return 1
}

# --- 编译 & 安装 ---
build_and_install() {
  log "配置/编译/安装 vnStat $VN_VER ..."
  ./configure --prefix=/usr --sysconfdir=/etc
  make -j"$(nproc)"
  make install
}

# --- 准备运行账户与数据目录 ---
prepare_runtime() {
  log "创建 vnstat 运行账号与数据库目录（若不存在） ..."
  getent group vnstat >/dev/null 2>&1 || groupadd -r vnstat
  getent passwd vnstat >/dev/null 2>&1 || useradd -r -g vnstat -M -d / -s /usr/sbin/nologin vnstat
  install -d -o vnstat -g vnstat /var/lib/vnstat
  # 可选：日志目录（如在 /etc/vnstat.conf 开启日志时）
  # install -d -o vnstat -g vnstat /var/log/vnstat
}

# --- 安装 systemd 服务并启用 ---
install_service() {
  log "安装 systemd service ..."
  # 不同版本 examples 路径可能微调，这里做个容错
  local svc_src=""
  if [[ -f "examples/systemd/vnstat.service" ]]; then
    svc_src="examples/systemd/vnstat.service"
  elif [[ -f "examples/systemd/system/vnstat.service" ]]; then
    svc_src="examples/systemd/system/vnstat.service"
  else
    err "未找到 vnstat.service 模板，请查看源码包 examples。"
    exit 1
  fi

  cp -fv "$svc_src" /etc/systemd/system/vnstat.service
  systemctl daemon-reload

  # 首次启动可能需要创建 DB，若服务文件含过严的 hardening 可临时注释后排障
  systemctl enable --now vnstat
}

# --- 将检测到的外网网卡加入数据库（可多次执行） ---
add_iface() {
  if [[ -n "${IFACE:-}" ]]; then
    log "检测到外网网卡：$IFACE，写入 vnStat 数据库 ..."
    vnstat --add -i "$IFACE" 2>/dev/null || true
  else
    warn "未检测到外网网卡，跳过 --add。可手动执行：vnstat --add -i <iface>"
  fi
}

# --- 验证 ---
verify() {
  log "验证服务与数据库 ..."
  sleep 2
  systemctl status vnstat --no-pager || true
  vnstat --dbiflist || true
  # 你偏好的一行统计（总字节）
  vnstat --oneline b || true
}

main() {
  require_root
  detect_latest
  log "最新版本：$VN_VER"
  install_deps
  fetch_and_extract
  if check_installed_same_version; then
    log "直接进行服务/网卡检查与验证 ..."
    detect_iface
    install_service || true
    add_iface
    verify
    return 0
  fi
  build_and_install
  prepare_runtime
  install_service
  detect_iface
  add_iface
  verify
  log "完成。"
}

# 入口
VN_VER=""; VN_URL=""
IFACE=""
main

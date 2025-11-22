#!/usr/bin/env bash
# 自动清理 doremii.top 临时网盘目录
#给执行权限：chmod +x /root/clean_doremii_temp.sh
# 超过 8GB 时，从最旧的文件开始删除，直到小于等于 8GB

set -euo pipefail

# ★ 这里改成你真实的 temp 目录（宿主机路径）
TEMP_DIR="/opt/1panel/www/sites/doremii.top/temp"

# ★ 上限：8GB（8 * 1024^3 字节）
MAX_BYTES=$((8 * 1024 * 1024 * 1024))

# 日志（可选，不想要可以把 LOG_FILE 设为空字符串 ""）
LOG_FILE="/var/log/clean_doremii_temp.log"

log() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
  fi
}

# 目录不存在就退出（不报错）
if [[ ! -d "$TEMP_DIR" ]]; then
  log "TEMP_DIR $TEMP_DIR 不存在，跳过。"
  exit 0
fi

# 当前目录大小（字节）
current_size=$(du -sb "$TEMP_DIR" | awk '{print $1}')

# 没超过上限就直接结束
if [[ "$current_size" -le "$MAX_BYTES" ]]; then
  exit 0
fi

log "当前目录大小 ${current_size} bytes，超过上限 ${MAX_BYTES}，开始清理旧文件..."

# 循环：每次删一个“最旧的文件”，直到目录大小 <= 上限
while [[ "$current_size" -gt "$MAX_BYTES" ]]; do
  # 找到最旧的 regular file（按修改时间排序）
  oldest_file=$(
    find "$TEMP_DIR" -type f -printf '%T@ %p\n' \
      | sort -n \
      | head -n 1 \
      | cut -d' ' -f2-
  )

  # 如果已经没有文件了，就退出
  if [[ -z "$oldest_file" ]]; then
    log "没有找到可删除的文件，退出。"
    break
  fi

  log "删除最旧文件：$oldest_file"
  rm -f -- "$oldest_file" || log "删除失败：$oldest_file"

  # 重新计算目录大小
  current_size=$(du -sb "$TEMP_DIR" | awk '{print $1}')
done

log "清理完成，当前目录大小：${current_size} bytes"


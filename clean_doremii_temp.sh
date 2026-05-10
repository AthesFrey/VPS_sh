#!/usr/bin/env bash
# 自动清理 doremii.top 临时网盘目录
# 超过 10GB 时，从最旧的文件开始删除，直到小于等于 10GB

set -euo pipefail

TEMP_DIR="/opt/1panel/www/sites/doremii.top/temp"
MAX_BYTES=$((10 * 1024 * 1024 * 1024))
LOG_FILE="/var/log/clean_doremii_temp.log"

# 只删除至少 30 分钟前修改过的文件，避免误删正在上传/写入的文件
MIN_AGE_MINUTES=30

log() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

if [[ ! -d "$TEMP_DIR" ]]; then
  log "TEMP_DIR $TEMP_DIR 不存在，跳过。"
  exit 0
fi

current_size=$(du -sb "$TEMP_DIR" | awk '{print $1}')

if [[ "$current_size" -le "$MAX_BYTES" ]]; then
  exit 0
fi

log "当前目录大小 ${current_size} bytes，超过上限 ${MAX_BYTES}，开始清理旧文件..."

while [[ "$current_size" -gt "$MAX_BYTES" ]]; do
  oldest_file=$(
    find "$TEMP_DIR" -type f -mmin +"$MIN_AGE_MINUTES" -printf '%T@ %p\n' \
      | sort -n \
      | head -n 1 \
      | cut -d' ' -f2-
  )

  if [[ -z "${oldest_file:-}" ]]; then
    log "没有找到可删除的文件，可能剩余文件都太新，退出。"
    break
  fi

  log "删除最旧文件：$oldest_file"

  if rm -f -- "$oldest_file"; then
    :
  else
    log "删除失败：$oldest_file"
  fi

  current_size=$(du -sb "$TEMP_DIR" | awk '{print $1}')
done

# 清理空子目录，不删除 TEMP_DIR 本身
find "$TEMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

log "清理完成，当前目录大小：${current_size} bytes"

#!/usr/bin/env bash
# Clean the temporary storage directory for doremii.top.
# When the directory exceeds 10 GiB, delete the oldest eligible files
# until the total apparent size is at or below the configured limit.

set -euo pipefail

TEMP_DIR="/opt/1panel/www/sites/doremii.top/temp"
MAX_BYTES=$((10 * 1024 * 1024 * 1024))
MIN_AGE_MINUTES=30
LOG_FILE="/var/log/clean_doremii_temp.log"
LOCK_FILE="/tmp/clean_doremii_temp.lock"

log() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
  fi
}

get_current_size() {
  du -sb -- "$TEMP_DIR" | awk 'NR == 1 { print $1 }'
}

find_oldest_eligible_file() {
  local record=""
  OLDEST_FILE=""

  # NUL-delimited records keep spaces, tabs, and newlines in filenames safe.
  # Avoiding "sort | head" prevents SIGPIPE from terminating the script
  # when pipefail is enabled and the directory contains many files.
  if IFS= read -r -d '' record < <(
    find "$TEMP_DIR" -type f -mmin +"$MIN_AGE_MINUTES" -printf '%T@ %p\0' \
      | sort -z -n
  ); then
    OLDEST_FILE="${record#* }"
    return 0
  fi

  return 1
}

# Prevent two scheduled cleanup jobs from deleting files at the same time.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Another cleanup process is already running; skipping this run."
    exit 0
  fi
fi

if [[ ! -d "$TEMP_DIR" ]]; then
  log "Temporary directory does not exist: $TEMP_DIR"
  exit 0
fi

current_size="$(get_current_size)"

if [[ "$current_size" -le "$MAX_BYTES" ]]; then
  exit 0
fi

log "Directory size is ${current_size} bytes; limit is ${MAX_BYTES} bytes. Starting cleanup."

while [[ "$current_size" -gt "$MAX_BYTES" ]]; do
  if ! find_oldest_eligible_file; then
    log "No eligible file was found. Remaining files may be newer than ${MIN_AGE_MINUTES} minutes."
    break
  fi

  log "Deleting oldest eligible file: $OLDEST_FILE"

  # Stop on deletion failure to avoid repeatedly selecting the same file.
  if ! rm -f -- "$OLDEST_FILE"; then
    log "Failed to delete file: $OLDEST_FILE"
    break
  fi

  current_size="$(get_current_size)"
done

# Remove empty subdirectories but keep TEMP_DIR itself.
find "$TEMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

log "Cleanup finished. Current directory size: ${current_size} bytes."



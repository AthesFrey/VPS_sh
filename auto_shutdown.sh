#!/usr/bin/env bash
set -Eeuo pipefail

# 统一环境，避免 locale/路径问题
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# === 可配置阈值（单位：GiB，1024^3）===
TRAFF_MONTH_TOTAL_GIB=500   # 每月额度（建议略小于ISP套餐上限）
TRAFF_DAY_TOTAL_GIB=17      # 每日额度（建议略小）

# 依赖检测
command -v vnstat >/dev/null 2>&1 || {
  echo "[error] vnstat 未安装。请先安装并确保已收集到数据。"
  exit 2
}

# 取今天日期（dumpdb 的月份/日期通常为不带前导零的整数，做个去零处理更保险）
Y=$(date +%Y)
M=$(date +%m | sed 's/^0\+//')
D=$(date +%d | sed 's/^0\+//')

# 从 dumpdb 解析：单位为 KiB（1024 字节）
# 月用量：m;year;month;rxKiB;txKiB;...
MONTH_KIB=$(
  vnstat --dumpdb | awk -F';' -v y="$Y" -v m="$M" '
    $1=="m" && $2==y && $3==m { sum = $4 + $5 } END { if (sum=="") sum=0; print sum }
'
)

# 日用量：d;year;month;day;rxKiB;txKiB;...
DAY_KIB=$(
  vnstat --dumpdb | awk -F';' -v y="$Y" -v m="$M" -v d="$D" '
    $1=="d" && $2==y && $3==m && $4==d { sum = $5 + $6 } END { if (sum=="") sum=0; print sum }
'
)

# KiB -> GiB（KiB / 1024^2 = GiB），使用整数除法，向下取整
MONTH_GIB=$(( MONTH_KIB / 1048576 ))
DAY_GIB=$(( DAY_KIB / 1048576 ))

printf '[info] %04d-%02d-%02d  已用：月=%d GiB  日=%d GiB\n' "$Y" "$M" "$D" "$MONTH_GIB" "$DAY_GIB"

# 先判月，再判日（或按你需要先判哪一个都行）
if (( MONTH_GIB >= TRAFF_MONTH_TOTAL_GIB )); then
  echo "[warn] Monthly traffic limit exceeded: ${MONTH_GIB} >= ${TRAFF_MONTH_TOTAL_GIB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
fi

if (( DAY_GIB >= TRAFF_DAY_TOTAL_GIB )); then
  echo "[warn] Daily traffic limit exceeded: ${DAY_GIB} >= ${TRAFF_DAY_TOTAL_GIB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
fi

exit 0

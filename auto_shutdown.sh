#!/usr/bin/env bash
# 流量阈值触发关机（vnstat oneline；GiB=1024^3；仅整数）
set -Eeuo pipefail
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TRAFF_MONTH_TOTAL_GiB=500   # 每月额度（GiB）
TRAFF_DAY_TOTAL_GiB=17      # 每日额度（GiB）

command -v vnstat >/dev/null 2>&1 || { echo "[error] vnstat 未安装" >&2; exit 2; }

# 直接用 vnstat 默认/当前接口；只取第一行，防科学计数法
TRAFF_USED=$(
  vnstat --oneline b \
  | awk -F';' 'NR==1{ if (NF>=11) { printf "%.0f\n", $11+0 } else { print 0 } ; exit }'
)
TRAFF_DAY_USED=$(
  vnstat --oneline b \
  | awk -F';' 'NR==1{ if (NF>=6)  { printf "%.0f\n", $6+0  } else { print 0 } ; exit }'
)

# 字节 -> GiB（整数）
MONTH_GiB=$(( TRAFF_USED / 1073741824 ))
DAY_GiB=$(( TRAFF_DAY_USED / 1073741824 ))

echo "[info] month=${MONTH_GiB}GiB  day=${DAY_GiB}GiB"

# 阈值判断：命中即关机并退出
if (( MONTH_GiB >= TRAFF_MONTH_TOTAL_GiB )); then
  echo "[warn] Monthly traffic limit exceeded: ${MONTH_GiB} >= ${TRAFF_MONTH_TOTAL_GiB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
  exit 0
fi

if (( DAY_GiB >= TRAFF_DAY_TOTAL_GiB )); then
  echo "[warn] Daily traffic limit exceeded: ${DAY_GiB} >= ${TRAFF_DAY_TOTAL_GiB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
  exit 0
fi

#!/usr/bin/env bash
# 流量阈值触发关机（按 vnstat oneline 取值；单位：GiB=1024^3；仅整数）
# 可选：IFACE=eth0 bash traffic_guard.sh 固定网卡

set -Eeuo pipefail
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TRAFF_MONTH_TOTAL_GiB=500   # 每月额度（GiB）
TRAFF_DAY_TOTAL_GiB=17      # 每日额度（GiB）

command -v vnstat >/dev/null 2>&1 || { echo "[error] vnstat 未安装" >&2; exit 2; }

# 可选固定接口
VNOPT=()
[ -n "${IFACE:-}" ] && VNOPT=(-i "$IFACE")

# oneline 取字节：NR==1 只取第一行，并防科学计数法
TRAFF_USED=$(
  vnstat "${VNOPT[@]}" --oneline b \
  | awk -F';' 'NR==1{ if (NF>=11) { printf "%.0f\n", $11+0 } else { print 0 } ; exit }'
)
TRAFF_DAY_USED=$(
  vnstat "${VNOPT[@]}" --oneline b \
  | awk -F';' 'NR==1{ if (NF>=6)  { printf "%.0f\n", $6+0  } else { print 0 } ; exit }'
)

# 字节 -> GiB（整数）
MONTH_GiB=$(( TRAFF_USED / 1073741824 ))
DAY_GiB=$(( TRAFF_DAY_USED / 1073741824 ))

echo "[info] iface=${IFACE:-default}  month=${MONTH_GiB}GiB  day=${DAY_GiB}GiB"

# 阈值判断：首个触发后退出，避免重复调用 shutdown（纯整洁处理）
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

#!/usr/bin/env bash
# 流量阈值触发关机（按 vnstat oneline 取值；单位：GiB=1024^3；仅整数）
# 可选：导出 IFACE 环境变量以固定网卡，例如：
#   IFACE=eth0 bash traffic_guard.sh

set -Eeuo pipefail
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ===== 配置（GiB，整数）=====
TRAFF_MONTH_TOTAL_GiB=500   # 每月额度（GiB，建议略小于套餐）
TRAFF_DAY_TOTAL_GiB=17      # 每日额度（GiB）

# ===== 依赖检查 =====
command -v vnstat >/dev/null 2>&1 || {
  echo "[error] vnstat 未安装" >&2
  exit 2
}

# ===== 取值（字节，整数；防科学计数法）=====
# 说明：$11=本月总字节，$6=今日总字节（来自 vnstat --oneline b）
# 支持通过 IFACE 固定接口：IFACE=eth0
VNOPT=()
if [ "${IFACE:-}" != "" ]; then
  VNOPT=(-i "$IFACE")
fi

TRAFF_USED=$(
  vnstat "${VNOPT[@]}" --oneline b | awk -F';' '
    NF>=11 {printf "%.0f\n", $11+0; f=1}
    END {if(!f) print 0}
  '
)
TRAFF_DAY_USED=$(
  vnstat "${VNOPT[@]}" --oneline b | awk -F';' '
    NF>=6 {printf "%.0f\n", $6+0; f=1}
    END {if(!f) print 0}
  '
)

# ===== 字节 -> GiB（整数，向下取整）=====
# 1073741824 = 1024^3
MONTH_GiB=$(( TRAFF_USED / 1073741824 ))
DAY_GiB=$(( TRAFF_DAY_USED / 1073741824 ))

echo "[info] iface=${IFACE:-default}  month=${MONTH_GiB}GiB  day=${DAY_GiB}GiB"

# ===== 阈值判断并关机 =====
if (( MONTH_GiB >= TRAFF_MONTH_TOTAL_GiB )); then
  echo "[warn] Monthly traffic limit exceeded: ${MONTH_GiB} >= ${TRAFF_MONTH_TOTAL_GiB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
fi

if (( DAY_GiB >= TRAFF_DAY_TOTAL_GiB )); then
  echo "[warn] Daily traffic limit exceeded: ${DAY_GiB} >= ${TRAFF_DAY_TOTAL_GiB} GiB. Shutting down..."
  /sbin/shutdown -h now || shutdown -h now
fi

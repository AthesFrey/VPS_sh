#!/usr/bin/env bash
# 指定解释器的方式
source /etc/profile
# 或者 source ~/.bashrc

TRAFF_MONTH_TOTAL=500 # 改成自己的预定额度，建议稍小些，单位GB
TRAFF_DAY_TOTAL=17   # 改成自己的预定额度，建议稍小些，单位GB

TRAFF_USED=$(vnstat --oneline b | awk -F';' '{print $11}')
MONTH_GB=$((TRAFF_USED / 1073741824))

TRAFF_DAY_USED=$(vnstat --oneline b | awk -F';' '{print $6}')
DAY_GB=$((TRAFF_DAY_USED / 1073741824))

if [ "$MONTH_GB" -ge "$TRAFF_MONTH_TOTAL" ]; then
    echo "Monthly traffic limit exceeded. Shutting down."
    sudo shutdown -h now
fi

if [ "$DAY_GB" -ge "$TRAFF_DAY_TOTAL" ]; then
    echo "Daily traffic limit exceeded. Shutting down."
    sudo shutdown -h now
fi

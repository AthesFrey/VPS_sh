#!/usr/bin/env bash
set -euo pipefail
LC_ALL=C

# 可用环境变量
D="${D:-$(date +%F)}"                         # 统计日期，默认今天
S="${S:-$D 00:00:00}"
E="${E:-$(date -d "$D +1 day" +%F) 00:00:00}"
EXCLUDE_DPT="${EXCLUDE_DPT:-22|443}"          # 默认排除 22/443
ONLY_DPT="${ONLY_DPT:-}"                       # 只看这些端口（正则 | 分隔），为空表示不限
LIMIT="${LIMIT:-50}"                           # 输出前 N 行
DEBUG="${DEBUG:-0}"

journalctl -k -S "$S" -U "$E" -o short-iso --no-pager \
| awk -v ex="$EXCLUDE_DPT" -v only="$ONLY_DPT" -v dbg="$DEBUG" '
function dport(line) {
  if (match(line, /DPT=[0-9]+/))   return substr(line,RSTART+4,RLENGTH-4)
  if (match(line, /dport=[0-9]+/)) return substr(line,RSTART+6,RLENGTH-6)
  if (match(line, /dport [0-9]+/)) return substr(line,RSTART+6,RLENGTH-6)
  return ""
}
function saddr(line) {
  if (match(line, /SRC=[0-9A-Fa-f:.]+/))   return substr(line,RSTART+4,RLENGTH-4)
  if (match(line, /saddr=[0-9A-Fa-f:.]+/)) return substr(line,RSTART+6,RLENGTH-6)
  return ""
}
function proto(line) {
  if (match(line, /PROTO=[A-Z]+/)) return substr(line,RSTART+6,RLENGTH-6)
  if (index(line," TCP ")>0) return "TCP"
  if (index(line," UDP ")>0) return "UDP"
  return "OTHER"
}
function ts_of(line, n,a) {
  if (match(line, /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/))
    return substr(line,RSTART,RLENGTH)
  n=split(line,a," "); if (n>0) return a[1]
  return ""
}
BEGIN { OFS=","; matched=0; }
{
  line=$0
  # 必须同时具备源地址/目的端口
  if (line !~ /(SRC=|saddr=)/) next
  if (line !~ /(DPT=|dport[ =])/ ) next

  ts   = ts_of(line)
  p    = proto(line)
  src  = saddr(line)
  dpt  = dport(line)

  if (src=="" || dpt=="") next
  if (only!="" && dpt !~ ("^(" only ")$")) next
  if (ex  !="" && dpt  ~ ("^(" ex   ")$")) next

  key = p "|" src "|" dpt
  if (!(key in first)) first[key]=ts
  last[key]=ts
  hits[key]++
  matched++
}
END {
  print "proto,src_ip,dst_port,first_seen,last_seen,hits"
  for (k in hits) {
    split(k,a,"|")
    print a[1],a[2],a[3],first[k],last[k],hits[k]
    groups++; total+=hits[k]
  }
  if (dbg=="1") {
    if (groups==0) {
      print "INFO: 没匹配到任何连接日志（检查 nft 规则/时间窗/排除端口）" > "/dev/stderr"
    } else {
      print "INFO: 匹配行=" matched ", 分组数=" groups ", 总 hits=" total > "/dev/stderr"
    }
  }
}' \
# 排序与截断（不写临时文件）
# shellcheck disable=SC2034
| ( IFS= read -r header; printf "%s\n" "$header"; sort -t, -k6,6nr | head -n "${LIMIT}" )

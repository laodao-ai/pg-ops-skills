#!/usr/bin/env bash
# cpu-attrib.sh —— 把整机 CPU 按进程归因，并把 postgres 后端关联到它当时在跑的 SQL
#
# 为什么需要它：pg_stat_statements 只能告诉你「SQL 执行花了多少 CPU」。当它给出的数
# （比如 0.8 核）和监控面板上的 CPU 曲线（比如 6 核）对不上时，差额可能在三个地方：
#   a) 根本不是 postgres 吃的（同机跑着应用 / EMQX / 日志采集）
#   b) 是 postgres 但不是 SQL 执行（连接建立 fork、WAL、checkpointer、autovacuum）
#   c) 采样窗口不一致（拿 A 时段的 pgss 去对 B 时段的曲线）
# 这个脚本一次把三者分开：直接读 /proc 算真实 CPU 时间差，不依赖 top 的输出格式。
#
# 用法： bash cpu-attrib.sh [观测秒数] [列出前几名]
#        bash cpu-attrib.sh 60 12
#
# 需要 root（读别的用户的 /proc/<pid>/stat 与 psql 连本地库）。

set -euo pipefail

DUR="${1:-60}"
TOPN="${2:-12}"
CLK="$(getconf CLK_TCK)"
CORES="$(nproc)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PGHOST="${PGHOST:-127.0.0.1}"; PGPORT="${PGPORT:-5432}"; PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER
PGDATABASE="${PGDATABASE:-postgres}"; export PGDATABASE

# /proc/<pid>/stat: comm 在括号里可能含空格，所以从 ") " 之后重新切分。
# 切分后 b[1]=state（原第 3 字段），故 utime(14)=b[12]、stime(15)=b[13]。
read_procs() {
    for f in /proc/[0-9]*/stat; do
        awk '{ n = split($0, a, ") "); split(a[n], b, " ");
               print $1, b[12] + b[13] }' "$f" 2>/dev/null || true
    done
}

echo "[*] 观测 ${DUR}s，${CORES} 核，CLK_TCK=${CLK}"

# 后台每秒采一次 pg_stat_activity，用于把 pid 还原成 SQL
(
    end=$(( $(date +%s) + DUR ))
    while [[ $(date +%s) -lt ${end} ]]; do
        psql -X -At -F'|' -c "
            SELECT pid, datname, application_name, state, wait_event_type,
                   left(regexp_replace(coalesce(query,''), '\s+', ' ', 'g'), 70)
            FROM pg_stat_activity
            WHERE state = 'active' AND pid <> pg_backend_pid()" 2>/dev/null >> "${TMP}/act" || true
        sleep 1
    done
) &
SAMPLER=$!

read_procs > "${TMP}/before"
grep '^cpu ' /proc/stat > "${TMP}/stat_before"
sleep "${DUR}"
grep '^cpu ' /proc/stat > "${TMP}/stat_after"
read_procs > "${TMP}/after"
wait "${SAMPLER}" 2>/dev/null || true

echo ""
echo "=== 整机 CPU 构成（/proc/stat 前后差值）==="
awk 'NR==1 { for (i=2; i<=NF; i++) a[i]=$i; next }
     NR==2 { tot=0; for (i=2; i<=NF; i++) { d[i]=$i-a[i]; tot+=d[i] }
             if (tot <= 0) { print "  （窗口太短，无差值）"; exit }
             user=d[2]+d[3]; sys=d[4]+d[7]+d[8]; idle=d[5]; iow=d[6]; steal=d[9]
             printf "  user %.1f%%   system %.1f%%   iowait %.1f%%   steal %.1f%%   idle %.1f%%\n",
                    100*user/tot, 100*sys/tot, 100*iow/tot, 100*steal/tot, 100*idle/tot
             busy = tot - idle - iow
             printf "  => 非 idle 合计 %.1f%%  ≈ %.2f / %d 核\n", 100*busy/tot, C*busy/tot, C }' \
    C="${CORES}" "${TMP}/stat_before" "${TMP}/stat_after"

echo ""
echo "=== 进程级 CPU 归因（前 ${TOPN} 名）==="
echo ""
join -j1 <(sort -k1,1 "${TMP}/before") <(sort -k1,1 "${TMP}/after") 2>/dev/null \
| awk -v clk="${CLK}" -v dur="${DUR}" -v cores="${CORES}" '
    { d = $3 - $2; if (d > 0) print $1, d }' \
| sort -k2,2nr | head -n "${TOPN}" \
| while read -r pid ticks; do
      comm="$(cat /proc/${pid}/comm 2>/dev/null || echo '<gone>')"
      cmd="$(tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null | cut -c1-70)"
      pct=$(awk -v t="${ticks}" -v c="${CLK}" -v d="${DUR}" -v n="${CORES}" \
                'BEGIN{printf "%.1f", 100*t/(c*d*n)}')
      corenum=$(awk -v t="${ticks}" -v c="${CLK}" -v d="${DUR}" \
                'BEGIN{printf "%.2f", t/(c*d)}')
      printf "  pid %-7s %6s%% of box  %5s core  %-16s %s\n" \
             "${pid}" "${pct}" "${corenum}" "${comm}" "${cmd}"
      # 这个 pid 在窗口里被 pg_stat_activity 抓到过什么
      if [[ -s "${TMP}/act" ]]; then
          awk -F'|' -v p="${pid}" '$1==p {print $2" ["$3"] "$5" :: "$6}' "${TMP}/act" \
            | sort | uniq -c | sort -rn | head -3 \
            | sed 's/^/                └─ /'
      fi
  done

echo ""
echo "=== 窗口内 active 后端的构成（按库/应用名）==="
if [[ -s "${TMP}/act" ]]; then
    awk -F'|' '{print $2" ["$3"]"}' "${TMP}/act" | sort | uniq -c | sort -rn | head -15
    echo ""
    echo "  采样点数：$(awk -F'|' '{print $1}' "${TMP}/act" | wc -l) 条 active 记录 / ${DUR} 次采样"
else
    echo "  （没抓到 active 后端）"
fi

echo ""
echo "注：pct_of_box 之和若远小于 /proc/stat 的非 idle 百分比，说明 CPU 花在了"
echo "    大量短命进程上（每秒 fork 出来又退出的，快照差法抓不到）——那种情况看 system%。"

#!/usr/bin/env bash
# pgss-delta.sh —— 取 pg_stat_statements 的「区间」快照差，得到真实的当前均值
#
# 为什么需要它：pg_stat_statements 的 mean_exec_time 是自 stats_reset 以来的累计均值。
# 在一台跑了半年的机器上，任何刚做的优化（比如 repack）都会被历史数据淹没，看不出效果。
# 取两次快照做差，才是「现在」的真实性能。
#
# 用法：  bash pgss-delta.sh [观测秒数] [行数] [连接用的库名]
#         bash pgss-delta.sh 300 20      # 默认：观测 5 分钟，出 top 20，库名自动探测
#
# 三个坑（都踩过，写在这里免得再踩）：
#
#  1) 视图按库建、内容跨库。pg_stat_statements 的**内容**是集群级的（每行带 dbid），
#     但它的**视图**只存在于跑过 CREATE EXTENSION 的库里。所以必须从一个装了扩展的库
#     连进去，然后 join pg_database 才看得出这条语句属于哪个库。不指定库名就自动找。
#
#  2) 两次快照必须 FULL OUTER / LEFT JOIN，不能 INNER JOIN。条目会被淘汰（dealloc）后
#     重建，重建后计数器归零，在第一次快照里根本不存在。用 INNER JOIN 会把这些
#     「窗口内新出现的语句」整类丢掉——而在 query text 数量远超 max 的机器上，
#     这恰恰是占比最大的一类。本脚本用 LEFT JOIN + coalesce(...,0)，并单独报告
#     「新出条目」占了多少，好判断这份采样本身可不可信。
#
#  3) total_exec_time 不含 parse / plan。track_planning 默认 off，此时 total_plan_time
#     恒为 0。SQL 文本不参数化 + 连接池 session 模式的 DISCARD ALL 会让 plan cache 反复
#     失效，规划开销可能是大头却完全不显形。脚本会打印 track_planning 的当前值；是 off
#     就先打开（SUSET，reload 即可，不用重启）：
#         ALTER SYSTEM SET pg_stat_statements.track_planning = on;
#         SELECT pg_reload_conf();

set -euo pipefail

WINDOW="${1:-300}"
LIMIT="${2:-20}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

has_pgss() {
    psql -X -At -d "$1" -c \
        "SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null \
        | grep -q '^1$'
}

# 库名：命令行第 3 参数 > PGDATABASE 环境变量 > 自动探测
PGDATABASE="${3:-${PGDATABASE:-}}"
if [[ -n "${PGDATABASE}" ]]; then
    has_pgss "${PGDATABASE}" || {
        echo "problem: 库 ${PGDATABASE} 里没有 pg_stat_statements 扩展" >&2; exit 1; }
else
    for db in $(psql -X -At -d postgres -c \
        "SELECT datname FROM pg_database
          WHERE datallowconn AND datname NOT IN ('template0','template1')
          ORDER BY pg_database_size(oid) DESC" 2>/dev/null); do
        if has_pgss "${db}"; then PGDATABASE="${db}"; break; fi
    done
    [[ -n "${PGDATABASE}" ]] || {
        echo "problem: 所有库里都找不到 pg_stat_statements 扩展。" >&2
        echo "         先在任一库执行 CREATE EXTENSION pg_stat_statements;" >&2
        echo "         （shared_preload_libraries 里已有该扩展时不需要重启）" >&2
        exit 1; }
    echo "[*] 自动选用库 ${PGDATABASE}（装了 pg_stat_statements）"
fi
export PGDATABASE

CORES="$(nproc 2>/dev/null || echo 8)"
TRACK_PLANNING="$(psql -X -At -c 'SHOW pg_stat_statements.track_planning' 2>/dev/null || echo '?')"

echo "[*] 观测窗口 ${WINDOW}s，机器 ${CORES} 核，连接 ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
echo "[*] track_planning = ${TRACK_PLANNING}"
if [[ "${TRACK_PLANNING}" != "on" ]]; then
    echo "[!] track_planning 是 ${TRACK_PLANNING}：plan 列会全是 0，规划开销看不见。"
    echo "[!] 打开（不用重启）： ALTER SYSTEM SET pg_stat_statements.track_planning=on; SELECT pg_reload_conf();"
fi
echo "[*] 开始快照，请勿中断……"

psql -X -q -v ON_ERROR_STOP=1 -v window="${WINDOW}" -v lim="${LIMIT}" -v cores="${CORES}" <<'SQL'
\timing off
\pset border 2

-- 快照 1：语句计数器 + 淘汰计数器
CREATE TEMP TABLE pgss_snap AS
SELECT s.userid, s.dbid, s.queryid,
       s.calls, s.total_exec_time, s.total_plan_time
FROM pg_stat_statements s
WHERE s.queryid IS NOT NULL;

CREATE TEMP TABLE pgss_info_snap AS
SELECT dealloc FROM pg_stat_statements_info;

SELECT pg_sleep(:window) \gset _sleep

-- 窗口内的增量：LEFT JOIN，把「窗口内新出现 / 被淘汰后重建」的条目也算进来
CREATE TEMP VIEW pgss_delta AS
SELECT d.datname                                      AS db,
       p.queryid IS NULL                              AS is_new,
       s.calls        - coalesce(p.calls, 0)          AS d_calls,
       s.total_exec_time - coalesce(p.total_exec_time, 0) AS d_exec_ms,
       s.total_plan_time - coalesce(p.total_plan_time, 0) AS d_plan_ms,
       s.mean_exec_time                               AS cum_mean_ms,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 80) AS query
FROM pg_stat_statements s
LEFT JOIN pgss_snap p
       ON p.userid = s.userid AND p.dbid = s.dbid AND p.queryid = s.queryid
JOIN pg_database d ON d.oid = s.dbid
WHERE s.calls > coalesce(p.calls, 0)
  AND s.query NOT ILIKE '%pg_sleep(%';   -- 排除本脚本自己的 sleep

\echo ''
\echo '=== 区间 top（按本窗口内 exec+plan 时间排序；new=t 表示该条目在窗口开始时不存在）==='
\echo ''

SELECT db,
       CASE WHEN is_new THEN 'Y' ELSE '' END          AS new,
       d_calls,
       round(d_calls::numeric / :window, 1)           AS calls_per_s,
       round((d_exec_ms)::numeric / 1000, 1)          AS d_exec_s,
       round((d_plan_ms)::numeric / 1000, 1)          AS d_plan_s,
       round(d_exec_ms::numeric / nullif(d_calls,0), 2) AS d_mean_ms,
       round(cum_mean_ms::numeric, 2)                 AS cum_mean_ms,
       round(100 * (d_exec_ms + d_plan_ms)::numeric
             / (:window * 1000 * :cores), 1)          AS pct_of_box,
       query
FROM pgss_delta
ORDER BY (d_exec_ms + d_plan_ms) DESC
LIMIT :lim;

\echo ''
\echo '=== 本窗口内各库合计（exec / plan 分开，new 单列）==='
\echo ''

SELECT db,
       sum(d_calls)                                                     AS d_calls,
       round(sum(d_exec_ms)::numeric/1000, 1)                           AS d_exec_s,
       round(sum(d_plan_ms)::numeric/1000, 1)                           AS d_plan_s,
       round(sum(d_exec_ms + d_plan_ms)::numeric / (:window*1000), 2)   AS cores_used,
       round(100 * sum(d_exec_ms + d_plan_ms)::numeric
             / (:window * 1000 * :cores), 1)                            AS pct_of_box,
       round(100 * (sum(d_exec_ms + d_plan_ms) FILTER (WHERE is_new))::numeric
             / nullif(sum(d_exec_ms + d_plan_ms)::numeric, 0), 1)                AS pct_from_new
FROM pgss_delta
GROUP BY 1
ORDER BY 5 DESC;

\echo ''
\echo '=== 全机合计 + 采样可信度 ==='
\echo ''

SELECT round(sum(d_exec_ms + d_plan_ms)::numeric / (:window*1000), 2)   AS cores_used,
       round(100 * sum(d_exec_ms + d_plan_ms)::numeric
             / (:window * 1000 * :cores), 1)                            AS pct_of_box,
       round(100 * sum(d_exec_ms)::numeric
             / nullif(sum(d_exec_ms + d_plan_ms)::numeric, 0), 1)                AS pct_exec,
       round(100 * sum(d_plan_ms)::numeric
             / nullif(sum(d_exec_ms + d_plan_ms)::numeric, 0), 1)                AS pct_plan,
       count(*) FILTER (WHERE is_new)                                   AS new_entries,
       round(100 * (sum(d_exec_ms + d_plan_ms) FILTER (WHERE is_new))::numeric
             / nullif(sum(d_exec_ms + d_plan_ms)::numeric, 0), 1)                AS pct_from_new
FROM pgss_delta;

SELECT (SELECT dealloc FROM pg_stat_statements_info) - (SELECT dealloc FROM pgss_info_snap)
                                                                        AS d_dealloc,
       round(((SELECT dealloc FROM pg_stat_statements_info)
              - (SELECT dealloc FROM pgss_info_snap))::numeric / :window, 2)
                                                                        AS dealloc_per_s,
       (SELECT count(*) FROM pg_stat_statements)                        AS entries_now,
       current_setting('pg_stat_statements.max')                        AS pgss_max;

\echo ''
\echo '注：pct_of_box = 该项占整机 CPU 的百分比（exec+plan）。'
\echo '    new=Y / pct_from_new 高 ⇒ 条目在被大量淘汰重建，说明 pg_stat_statements.max 太小。'
\echo '    d_dealloc > 0 ⇒ 窗口内发生了淘汰，每次淘汰都要在排它锁下排序并重写 query text 文件。'
SQL

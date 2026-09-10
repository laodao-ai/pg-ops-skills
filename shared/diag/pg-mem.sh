#!/usr/bin/env bash
# pg-mem.sh —— 看 PostgreSQL 的内存到底被谁占着，区分「共享缓冲区」「后端私有」「文件缓存」
#
# 用在什么场景：把短命连接改成常驻连接（上连接池）之后，内存占用开始上涨。
# 常见误判有两个：
#   a) 把 page cache 当成"用掉的内存"——它可以随时被回收，MemAvailable 才是真的余量
#   b) 用 RSS 给后端排序——每个后端都把 shared_buffers 映射进自己地址空间，RSS 会重复计算
#      几个 GB。要看 smaps_rollup 里的 Private_Clean+Private_Dirty，那才是这个后端独占的。
#
# 后端私有内存的主要成分是 relcache / catcache：后端碰过哪张表就缓存该表的目录项，
# **PostgreSQL 不会主动回收**。表越多涨得越猛（本机 8000+ 张 data.n_* 表）。
# 它的天然上限是连接被回收重建：PgBouncer 的 server_lifetime（默认 3600s）到点强制换连接。
#
# 用法： bash pg-mem.sh [列出前几名]      需要 root（读别的用户的 /proc/<pid>/smaps_rollup）

set -euo pipefail
TOPN="${1:-20}"

PGHOST="${PGHOST:-127.0.0.1}"; PGPORT="${PGPORT:-5432}"; PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

echo "=== 1. 整机内存：云监控的百分比 vs 真实余量 ==="
echo ""
free -m | sed 's/^/  /'
echo ""
awk '/^(MemTotal|MemFree|MemAvailable|Buffers|^Cached|Shmem|Dirty):/ {printf "  %-14s %8.0f MB\n", $1, $2/1024}' /proc/meminfo
grep -E '^(Cached|SReclaimable):' /proc/meminfo | awk '{printf "  %-14s %8.0f MB\n", $1, $2/1024}'
echo ""
awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
     END{printf "  => 真实可用 %.0f MB / %.0f MB（%.1f%%）。云监控若把 page cache 算成已用，\n     它的百分比会比这个高得多，看这一行不看那个百分比。\n", a/1024, t/1024, 100*a/t}' /proc/meminfo

echo ""
echo "=== 2. 后端私有内存（Private_Clean + Private_Dirty，已排除共享缓冲区）==="
echo ""
psql -X -w -At -F'|' -c "
    SELECT pid, coalesce(datname,'-'), coalesce(application_name,'-'),
           to_char(backend_start,'HH24:MI:SS'),
           extract(epoch from now()-backend_start)::int
    FROM pg_stat_activity WHERE backend_type='client backend'" 2>/dev/null > /tmp/.pgmem_act || true

TOTAL=0
{
    for f in /proc/[0-9]*/smaps_rollup; do
        pid="${f#/proc/}"; pid="${pid%/smaps_rollup}"
        comm="$(cat /proc/${pid}/comm 2>/dev/null || true)"
        [[ "${comm}" == "postgres" || "${comm}" == "pgbouncer" ]] || continue
        priv="$(awk '/^Private_Clean:|^Private_Dirty:/ {s+=$2} END {print s+0}' "${f}" 2>/dev/null || echo 0)"
        [[ "${priv}" -gt 0 ]] 2>/dev/null || continue
        info="$(awk -F'|' -v p="${pid}" '$1==p {print $2" ["$3"] 建于 "$4" 已活 "$5"s"}' /tmp/.pgmem_act)"
        [[ -n "${info}" ]] || info="$(tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null | cut -c1-58)"
        echo "${priv} ${pid} ${info}"
    done
} | sort -nr > /tmp/.pgmem_rows

head -n "${TOPN}" /tmp/.pgmem_rows | while read -r priv pid rest; do
    printf "  %8.1f MB  pid %-8s %s\n" "$(awk -v k="${priv}" 'BEGIN{print k/1024}')" "${pid}" "${rest}"
done

awk '{s+=$1; n++} END {printf "\n  合计 %d 个进程，私有内存 %.2f GB（平均每个 %.1f MB）\n", n, s/1048576, s/1024/n}' /tmp/.pgmem_rows

echo ""
echo "=== 3. 后端数量与年龄分布（决定 server_lifetime 会不会兜住）==="
echo ""
psql -X -w -c "
    SELECT coalesce(datname,'-') AS db, count(*) AS 后端数,
           to_char(min(backend_start),'HH24:MI:SS') AS 最早,
           to_char(max(backend_start),'HH24:MI:SS') AS 最新,
           (max(extract(epoch from now()-backend_start))/60)::int AS 最老几分钟
    FROM pg_stat_activity WHERE backend_type='client backend'
    GROUP BY 1 ORDER BY 2 DESC" 2>/dev/null | sed 's/^/  /'

rm -f /tmp/.pgmem_act /tmp/.pgmem_rows
echo ""
echo "判读："
echo "  - 看第 1 段的「真实可用」，不要看云监控的百分比（它多半把 page cache 算成已用）。"
echo "  - 第 2 段单个后端私有内存持续增长且不回落 ⇒ relcache/catcache 累积（表多的库必然如此）。"
echo "  - 第 3 段「最老几分钟」若接近 PgBouncer 的 server_lifetime/60，说明马上会集体回收，"
echo "    内存会掉一截 ⇒ 这是每小时的锯齿，不是泄漏，不必处理。"
echo "  - 真要压：调小 PgBouncer 的 default_pool_size（按实际并发，不是按 max_client_conn），"
echo "    或调小 server_lifetime（用一点点 fork 成本换一个更低的内存上限）。"

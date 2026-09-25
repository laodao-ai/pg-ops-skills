#!/usr/bin/env bash
# conn-storm.sh —— 诊断「连接风暴」：每秒建了多少连接、哪个库、谁建的、池有没有起作用
#
# 用在什么场景：整机 CPU 里 system% 高于 user%，且进程级归因认领不到（因为进程活不过
# 1 秒）。这种形状说明 CPU 花在 fork/初始化/销毁后端上，不是花在算数据上。
#
# 回答五个问题：
#   1. 每秒建多少连接？周期形状是什么（按分钟内秒位聚合，不用卡时间点）
#   2. 哪个库最凶？每个连接平均只干几个事务（<10 = 池等于没用）
#   3. 谁在建（库 / 用户 / 应用名 / 来源地址）
#   4. PgBouncer 什么模式、峰期 sv_login / cl_waiting 是多少
#      —— sv_login 峰期 > 0 ⇒ fork 是 PgBouncer 发起的（池太小或在 churn）
#      —— sv_login 峰期 = 0 但 PG 侧建连速率很高 ⇒ 有应用绕过池直连 5432
#   5. PgBouncer 自己统计的请求量（SHOW STATS 前后差）
#
# 用法： bash conn-storm.sh [观测秒数]
#        PGBOUNCER_PASS=xxx bash conn-storm.sh 300              # 管理库要密码时
#        BOUNCER_PORT=6432 bash conn-storm.sh 300               # 读不到 ini 时直接指定端口
#
# 建议用 root 跑（否则读不到 /etc/pgbouncer/*.ini 与 ss -lntp 的进程名，第 0/4/5 段会降级；
# 第 1-3 段只靠 PostgreSQL 自己的计数器，普通用户也能跑）。分析用 python3。所有 psql 都带 -w（绝不弹密码提示），连不上就跳过，不卡住。
# 说明：pg_stat_database.sessions 在后端启动时 +1（PG 14+），共享内存统计最长约 1 秒刷新
#       一次，单秒有抖动，看聚合形状不看单点。

set -euo pipefail

DUR="${1:-300}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

command -v python3 >/dev/null || { echo "problem: 需要 python3 做分析" >&2; exit 1; }

PGHOST="${PGHOST:-127.0.0.1}"; PGPORT="${PGPORT:-5432}"; PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

psql -X -w -At -c 'SELECT 1' >/dev/null 2>&1 || {
    echo "problem: 连不上 ${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}" >&2; exit 1; }

# ───────────────────────── 0. PgBouncer 现状 ─────────────────────────
echo "=== 0. PgBouncer 现状 ==="
echo ""
[[ "$(id -u)" == "0" ]] || echo "  [!] 不是 root：配置文件与进程名读不到，第 0/4/5 段会降级"
echo "--- 监听中的端口 ---"
(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | grep -E 'pgbouncer|postgres|:6432|:7432' \
    | sed 's/^/  /' || echo "  （拿不到监听列表）"
echo ""
for ini in /etc/pgbouncer/*.ini; do
    [[ -r "${ini}" ]] || { echo "--- ${ini}：读不到（需要 root）---"; echo ""; continue; }
    echo "--- ${ini} 的有效配置 ---"
    grep -vE '^\s*(#|;|$)' "${ini}" | sed 's/^/  /'
    echo ""
done

# 找一条能用的 PgBouncer 管理库连法，存进 BPORT/BUSER/BHOST，后面采样复用
# 端口：BOUNCER_PORT 环境变量 > 从 ini 里读 > 默认试 6432 / 7432
PORTS="${BOUNCER_PORT:-}"
ADMINS=""
for ini in /etc/pgbouncer/*.ini; do
    [[ -r "${ini}" ]] || continue
    [[ -n "${BOUNCER_PORT:-}" ]] || PORTS+=" $(awk -F'=' '/^[[:space:]]*listen_port/{gsub(/[[:space:]]/,"",$2); print $2}' "${ini}")"
    ADMINS+=" $(awk -F'=' '/^[[:space:]]*admin_users/{print $2}' "${ini}" | tr -d '[:space:]' | tr ',' ' ')"
done
[[ -n "${PORTS// /}" ]] || PORTS="6432 7432"

BPORT=""; BUSER=""; BHOST=""
for port in ${PORTS}; do
    for u in ${ADMINS} pgbouncer postgres; do
        for h in /var/run/postgresql /tmp 127.0.0.1; do
            if PGPASSWORD="${PGBOUNCER_PASS:-}" psql -X -w -At -h "${h}" -p "${port}" \
                   -U "${u}" pgbouncer -c 'SHOW VERSION;' >/dev/null 2>&1; then
                BPORT="${port}"; BUSER="${u}"; BHOST="${h}"; break 3
            fi
        done
    done
done

bpsql() { PGPASSWORD="${PGBOUNCER_PASS:-}" psql -X -w -h "${BHOST}" -p "${BPORT}" \
              -U "${BUSER}" pgbouncer "$@" 2>/dev/null; }

if [[ -n "${BPORT}" ]]; then
    echo "--- PgBouncer 管理库：${BUSER}@${BHOST}:${BPORT} ---"
    bpsql -c 'SHOW POOLS;'   | sed 's/^/  /'
    bpsql -c 'SHOW CLIENTS;' | head -25 | sed 's/^/  /'
    bpsql -At -F'|' -c 'SHOW STATS;' > "${TMP}/stats_before" || true
else
    echo "  （连不上 PgBouncer 管理库。看上面 ini 里的 admin_users；"
    echo "    要密码就 PGBOUNCER_PASS=xxx ./conn-storm.sh 300 重跑）"
fi

# ───────────────────────── 1. 采样 ─────────────────────────
echo ""
echo "=== 采样 ${DUR}s（每秒 1 次），随时可起跑、不用卡时间点，请勿中断…… ==="

for ((i = 0; i < DUR; i++)); do
    NOW="$(date +%s)"

    psql -X -w -At -F'|' -c "
        SELECT datname, sessions, xact_commit, numbackends
        FROM pg_stat_database WHERE datname IS NOT NULL AND sessions > 0
        " 2>/dev/null | sed "s/^/${NOW}|/" >> "${TMP}/db" || true

    psql -X -w -At -F'|' -c "
        SELECT pid, extract(epoch from backend_start)::bigint,
               coalesce(datname,'-'), coalesce(usename,'-'),
               coalesce(application_name,'-'),
               coalesce(host(client_addr),'local')
        FROM pg_stat_activity
        WHERE backend_type = 'client backend'
          AND backend_start > now() - interval '2 seconds'
        " 2>/dev/null | sed "s/^/${NOW}|/" >> "${TMP}/new" || true

    if [[ -n "${BPORT}" ]]; then
        bpsql -At -F'|' -c 'SHOW POOLS;' | sed "s/^/${NOW}|/" >> "${TMP}/pools" || true
    fi

    sleep "$(awk -v n="$(date +%s.%N)" 'BEGIN { d = 1 - (n - int(n)); print (d > 0.02 ? d : 0.02) }')"
done

if [[ -n "${BPORT}" ]]; then
    bpsql -At -F'|' -c 'SHOW STATS;' > "${TMP}/stats_after" || true
fi

echo "[*] 分析中……"

# ───────────────────────── 2. 分析 ─────────────────────────
TMP="${TMP}" DUR="${DUR}" python3 - <<'PY'
import os, collections

TMP = os.environ['TMP']

def readf(name):
    try:
        return open(f'{TMP}/{name}').read().splitlines()
    except FileNotFoundError:
        return []

# ---- 每秒 pg_stat_database 快照 ----
snap = collections.defaultdict(dict)
for line in readf('db'):
    f = line.split('|')
    if len(f) == 5:
        snap[int(f[0])][f[1]] = (int(f[2]), int(f[3]), int(f[4]))

ts = sorted(snap)
if len(ts) < 3:
    raise SystemExit('problem: 样本太少')

rate_all = {}
for t0, t1 in zip(ts, ts[1:]):
    if t1 - t0 != 1:
        continue
    tot = 0
    for db, v1 in snap[t1].items():
        if db in snap[t0]:
            d = v1[0] - snap[t0][db][0]
            if d >= 0:
                tot += d
    rate_all[t1] = tot

print('\n=== 1. 建连速率的周期形状（按分钟内的第几秒聚合）===\n')
by_sec = collections.defaultdict(list)
for t, v in rate_all.items():
    by_sec[t % 60].append(v)
peak_v = max((sum(v) / len(v) for v in by_sec.values()), default=1) or 1
for s in range(60):
    if s in by_sec:
        m = sum(by_sec[s]) / len(by_sec[s])
        print(f'  :{s:02d}  {m:7.1f} 个/秒  {"#" * int(round(40 * m / peak_v))}')

vals   = sorted(rate_all.items(), key=lambda kv: kv[1])
k      = max(1, len(vals) // 4)
trough = {t for t, _ in vals[:k]}
peak   = {t for t, _ in vals[-k:]}
pa = sum(rate_all[t] for t in peak) / len(peak)
ga = sum(rate_all[t] for t in trough) / len(trough)
print(f'\n  峰期 {pa:.1f} 个/秒   谷期 {ga:.1f} 个/秒   差 {pa - ga:+.1f} 个/秒')
print(f'  按每个后端 fork+初始化 5 / 10 / 15 ms 估算，峰期光建连就要 '
      f'{(pa-ga)*0.005:.2f} / {(pa-ga)*0.010:.2f} / {(pa-ga)*0.015:.2f} 核')

# ---- 各库 ----
print('\n=== 2. 各库：建连总量与「每连接干几个事务」===\n')
print(f'  {"库":<14} {"新建会话":>9} {"每秒":>7} {"事务数":>10} {"每连接事务":>11} {"当前连接":>9}')
first, last, span = snap[ts[0]], snap[ts[-1]], ts[-1] - ts[0]
rows = []
for db in last:
    if db in first:
        ds = last[db][0] - first[db][0]
        dx = last[db][1] - first[db][1]
        if ds > 0 or dx > 0:
            rows.append((ds, db, dx, last[db][2]))
for ds, db, dx, nb in sorted(rows, reverse=True):
    per  = (dx / ds) if ds else float('inf')
    flag = '  ← 池等于没用' if 0 < ds and per < 10 else ''
    print(f'  {db:<14} {ds:9d} {ds/span:7.1f} {dx:10d} {per:11.1f} {nb:9d}{flag}')

# ---- 谁在建 ----
seen = {}
for line in readf('new'):
    f = line.split('|')
    if len(f) == 7:
        seen[(f[1], f[2])] = (f[3], f[4], f[5], f[6])
print(f'\n=== 3. 谁在建连（抓到 {len(seen)} 个新后端；活不到 1 秒的抓不全，看比例不看绝对值）===\n')
for title, key in (('库 / 用户 / 应用名', lambda v: f'{v[0]} / {v[1]} / {v[2]}'),
                   ('来源地址',           lambda v: v[3])):
    print(f'  --- 按{title} ---')
    for k2, n in collections.Counter(key(v) for v in seen.values()).most_common(12):
        print(f'    {n:7d}  {k2}')
    print()

# ---- PgBouncer 池状态：峰期 vs 谷期 ----
pools = collections.defaultdict(lambda: collections.defaultdict(dict))   # db -> field -> {epoch: v}
COL = {'cl_active': 2, 'cl_waiting': 3, 'sv_active': 6, 'sv_idle': 9,
       'sv_used': 10, 'sv_login': 12, 'maxwait': 13}
modes = {}
for line in readf('pools'):
    f = line.split('|')
    if len(f) < 17:
        continue
    t, db = int(f[0]), f[1]
    modes[db] = f[16]
    for name, i in COL.items():
        try:
            pools[db][name][t] = int(f[i + 1])
        except ValueError:
            pass

if pools:
    print('=== 4. PgBouncer 池状态：峰期 vs 谷期（每秒采样的平均值）===\n')
    print(f'  {"库":<12} {"模式":<11} {"cl_active":>10} {"cl_waiting":>11} '
          f'{"sv_active":>10} {"sv_idle":>8} {"sv_login":>9} {"maxwait":>8}')
    for db in sorted(pools):
        def avg(field, sel):
            v = [pools[db][field][t] for t in sel if t in pools[db][field]]
            return sum(v) / len(v) if v else 0.0
        for label, sel in (('峰', peak), ('谷', trough)):
            print(f'  {db + " " + label:<12} {modes.get(db,"?"):<11} '
                  f'{avg("cl_active",sel):10.1f} {avg("cl_waiting",sel):11.1f} '
                  f'{avg("sv_active",sel):10.1f} {avg("sv_idle",sel):8.1f} '
                  f'{avg("sv_login",sel):9.2f} {avg("maxwait",sel):8.1f}')
    print()
    print('  判读：sv_login 峰期 > 0  ⇒ PgBouncer 在新建服务端连接，fork 由它发起'
          '（池太小 / server_lifetime 太短）')
    print('        sv_login 峰期 ≈ 0 但第 1 段建连速率很高 ⇒ 有应用绕过池直连 5432')
    print('        cl_waiting > 0 ⇒ 池已排队，pool_size 不够')
    print()

# ---- SHOW STATS 前后差 ----
sb = {l.split('|')[0]: l.split('|') for l in readf('stats_before') if '|' in l}
sa = {l.split('|')[0]: l.split('|') for l in readf('stats_after')  if '|' in l}
if sb and sa:
    print(f'=== 5. PgBouncer SHOW STATS 前后差（{span}s 窗口）===\n')
    print(f'  {"库":<14} {"xact":>10} {"query":>10} {"received":>12} {"sent":>12}')
    for db in sa:
        if db in sb:
            try:
                d = [int(sa[db][i]) - int(sb[db][i]) for i in (1, 2, 3, 4)]
            except (ValueError, IndexError):
                continue
            if any(d):
                print(f'  {db:<14} {d[0]:10d} {d[1]:10d} {d[2]:12d} {d[3]:12d}')
    print()

print('注：「每连接事务数」< 10 ⇒ 连一次只干一两件事就断，池没起作用。')
print('    健康的长连接 / 事务级池，这个数是几百到几万。')
PY

#!/usr/bin/env bash
# cpu-phase.sh —— 定位「周期性 CPU 尖峰」到底是谁在吃
#
# 和 cpu-attrib / pgss-delta 的区别：那两个都是**整窗口平均**，会把峰和谷平均掉，
# 对周期性尖峰完全无效。这个脚本每秒采一次样，按「分钟内的第几秒」归档，然后
# 直接给出「峰期 减 谷期」的差值——多出来的那部分就是尖峰的成因。
#
# 每秒同时采三样东西，保证三者时间戳对齐：
#   1. /proc/stat        → 整机 CPU（user/system/iowait），确认尖峰是不是 postgres 吃的
#   2. /proc/<pid>/stat  → 每个进程的 CPU tick，归因到具体进程
#   3. pg_stat_activity  → active 后端在跑什么 SQL，归因到具体语句
#
# 用法： bash cpu-phase.sh [观测秒数]
#        bash cpu-phase.sh 300        # 建议至少 180s，跨 3 个以上周期
#
# 需要 root。分析部分用 python3（Ubuntu 自带）。

set -euo pipefail

DUR="${1:-300}"
CLK="$(getconf CLK_TCK)"
CORES="$(nproc)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

command -v python3 >/dev/null || { echo "problem: 需要 python3 做分析" >&2; exit 1; }

PGHOST="${PGHOST:-127.0.0.1}"; PGPORT="${PGPORT:-5432}"; PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

echo "[*] 采样 ${DUR}s（每秒 1 次），${CORES} 核，CLK_TCK=${CLK}"
echo "[*] 采集中，请勿中断……"

for ((i = 0; i < DUR; i++)); do
    NOW="$(date +%s)"

    echo "${NOW} $(grep '^cpu ' /proc/stat)" >> "${TMP}/cpu"

    # /proc/<pid>/stat：comm 在括号里可能含空格，从 ") " 之后重切；b[12]+b[13] = utime+stime
    awk -v t="${NOW}" '{ n = split($0, a, ") "); split(a[n], b, " ");
                         print t, $1, b[12] + b[13] }' \
        /proc/[0-9]*/stat 2>/dev/null >> "${TMP}/procs" || true

    psql -X -At -F'|' -c "
        SELECT pid, coalesce(datname,'-'), coalesce(application_name,'-'),
               coalesce(wait_event_type,'CPU'),
               left(regexp_replace(coalesce(query,''), '\s+', ' ', 'g'), 70)
        FROM pg_stat_activity
        WHERE state = 'active' AND pid <> pg_backend_pid() AND backend_type = 'client backend'
        " 2>/dev/null | sed "s/^/${NOW}|/" >> "${TMP}/act" || true

    # 对齐到下一整秒
    sleep "$(awk -v n="$(date +%s.%N)" 'BEGIN { d = 1 - (n - int(n)); print (d > 0.02 ? d : 0.02) }')"
done

echo "[*] 采集完成，分析中……"

CLK="${CLK}" CORES="${CORES}" TMP="${TMP}" python3 - <<'PY'
import os, collections

CLK   = int(os.environ['CLK'])
CORES = int(os.environ['CORES'])
TMP   = os.environ['TMP']

# ---------- 1. 每秒整机 CPU ----------
rows = []
for line in open(f'{TMP}/cpu'):
    f = line.split()
    rows.append((int(f[0]), [int(x) for x in f[2:]]))
rows.sort()

busy_at = {}          # epoch -> (busy%, user%, sys%, iowait%)
for (t0, a), (t1, b) in zip(rows, rows[1:]):
    if t1 - t0 <= 0:
        continue
    d = [y - x for x, y in zip(a, b)]
    tot = sum(d)
    if tot <= 0:
        continue
    idle, iow = d[3], d[4]
    user, sys_ = d[0] + d[1], d[2] + (d[5] if len(d) > 5 else 0) + (d[6] if len(d) > 6 else 0)
    busy_at[t1] = (100 * (tot - idle - iow) / tot,
                   100 * user / tot, 100 * sys_ / tot, 100 * iow / tot)

if not busy_at:
    raise SystemExit('problem: 没采到有效样本')

# ---------- 2. 按「分钟内第几秒」聚合，画出周期形状 ----------
by_sec = collections.defaultdict(list)
for t, v in busy_at.items():
    by_sec[t % 60].append(v[0])

print('\n=== 周期形状：按分钟内的第几秒聚合的平均 CPU% ===\n')
peak_v = max(sum(v) / len(v) for v in by_sec.values())
for s in range(60):
    if s not in by_sec:
        continue
    m = sum(by_sec[s]) / len(by_sec[s])
    bar = '#' * int(round(40 * m / max(peak_v, 1)))
    print(f'  :{s:02d}  {m:5.1f}%  {bar}')

# ---------- 3. 自动切峰 / 谷 ----------
vals = sorted(busy_at.items(), key=lambda kv: kv[1][0])
n    = len(vals)
k    = max(1, n // 4)
trough = {t for t, _ in vals[:k]}
peak   = {t for t, _ in vals[-k:]}

def avg(sel, i):
    return sum(busy_at[t][i] for t in sel) / len(sel)

print(f'\n=== 峰期 vs 谷期（各取 {k} 秒 / 共 {n} 秒）===\n')
print(f'  {"":8} {"CPU busy":>9} {"user":>8} {"system":>8} {"iowait":>8}')
for name, sel in (('峰期', peak), ('谷期', trough)):
    print(f'  {name:8} {avg(sel,0):8.1f}% {avg(sel,1):7.1f}% {avg(sel,2):7.1f}% {avg(sel,3):7.1f}%')
print(f'  {"差值":8} {avg(peak,0)-avg(trough,0):8.1f}% {avg(peak,1)-avg(trough,1):7.1f}%'
      f' {avg(peak,2)-avg(trough,2):7.1f}% {avg(peak,3)-avg(trough,3):7.1f}%'
      f'   ≈ {CORES*(avg(peak,0)-avg(trough,0))/100:.2f} 核')

# ---------- 4. 进程级：峰期比谷期多吃了多少 ----------
ticks = collections.defaultdict(dict)          # pid -> {epoch: ticks}
for line in open(f'{TMP}/procs'):
    f = line.split()
    if len(f) == 3:
        ticks[f[1]][int(f[0])] = int(f[2])

ts = sorted(busy_at)
rate = collections.defaultdict(dict)           # pid -> {epoch: ticks/s}
for pid, series in ticks.items():
    for t in ts:
        if t in series and (t - 1) in series:
            rate[pid][t] = series[t] - series[t - 1]

def pid_avg(pid, sel):
    v = [rate[pid][t] for t in sel if t in rate[pid]]
    return sum(v) / len(v) if v else 0.0

def name_of(pid):
    try:
        comm = open(f'/proc/{pid}/comm').read().strip()
    except OSError:
        comm = '<gone>'
    try:
        cmd = open(f'/proc/{pid}/cmdline').read().replace('\0', ' ').strip()[:60]
    except OSError:
        cmd = ''
    return comm, cmd

diffs = []
for pid in rate:
    p, g = pid_avg(pid, peak), pid_avg(pid, trough)
    if p - g > 0.01:
        diffs.append((p - g, p, g, pid))
diffs.sort(reverse=True)

print('\n=== 进程级：峰期 − 谷期（tick/s → 占整机核数）===\n')
print(f'  {"多出的核":>9} {"峰期核":>8} {"谷期核":>8}  pid      进程')
for d, p, g, pid in diffs[:15]:
    comm, cmd = name_of(pid)
    print(f'  {d/CLK:9.3f} {p/CLK:8.3f} {g/CLK:8.3f}  {pid:<8} {comm:<16} {cmd}')
print(f'\n  峰谷差合计 {sum(d for d,_,_,_ in diffs)/CLK:.2f} 核'
      f'（整机峰谷差 {CORES*(avg(peak,0)-avg(trough,0))/100:.2f} 核）')

# ---------- 5. active 后端：峰期比谷期多出哪些 SQL ----------
act = collections.defaultdict(list)            # epoch -> [(pid,db,app,wait,query)]
try:
    for line in open(f'{TMP}/act'):
        f = line.rstrip('\n').split('|', 5)
        if len(f) == 6:
            act[int(f[0])].append(tuple(f[1:]))
except FileNotFoundError:
    act = {}

def count(sel, key):
    c = collections.Counter()
    for t in sel:
        for r in act.get(t, []):
            c[key(r)] += 1
    return c, len(sel)

for title, key in (('库 [应用名]', lambda r: f'{r[1]} [{r[2]}]'),
                   ('等待事件',    lambda r: r[3]),
                   ('SQL',         lambda r: r[4][:66])):
    cp, np_ = count(peak, key)
    cg, ng  = count(trough, key)
    print(f'\n=== active 后端构成：{title}（每秒平均个数）===\n')
    print(f'  {"峰期":>7} {"谷期":>7} {"差值":>7}   {title}')
    rowsx = [(cp[k] / np_ - cg[k] / ng, cp[k] / np_, cg[k] / ng, k)
             for k in set(cp) | set(cg)]
    for d, p, g, k in sorted(rowsx, reverse=True)[:12]:
        print(f'  {p:7.2f} {g:7.2f} {d:+7.2f}   {k}')

print('\n注：进程级「多出的核」若合计 ≈ 整机峰谷差 ⇒ 尖峰有明确归属，看第一名是谁。')
print('    若远小于整机峰谷差 ⇒ 尖峰来自每秒 fork/exit 的短命进程（快照差抓不到），看 system% 是否同步升高。')
print('    若峰期 postgres 进程没多吃、但 CPU 高 ⇒ 尖峰根本不在数据库，看进程列表里的其它名字。')
PY

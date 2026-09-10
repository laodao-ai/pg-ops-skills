# Runbook：表膨胀处置 —— pgstattuple 量化 + pg_repack 在线压缩

> 2026-09-05 起草。首个应用场景是一张 7,771 行却占 4462 MB 的表——行数与物理大小差三个数量级，是典型的膨胀信号。
> 本文是人读 runbook，不含项目参数；例子里的库名 / 表名换成自己的即可。

## 1. 两个扩展各做什么

### 1.1 pgstattuple —— 只读量化，回答「这张表膨胀了多少」

- PostgreSQL 自带的 contrib 扩展，PGDG 的 `postgresql-<N>` 包已带，只需 `CREATE EXTENSION`。
- `pgstattuple('schema.table')` 逐页扫表，返回：`table_len`（表物理大小）、`tuple_percent`（活元组占比）、
  `dead_tuple_percent`（死元组占比）、`free_percent`（空闲空间占比）。
- **判断规则**：`tuple_percent` 个位数、其余两项占大头 ⇒ 膨胀，值得 repack。
  `pg_stat_user_tables.n_dead_tup` 只是估算，pgstattuple 是实测。
- 代价：全表顺序扫描，只加 ACCESS SHARE 锁，不阻塞读写；几 GB 的表秒级到分钟级。
  超大表用 `pgstattuple_approx()` 抽样即可。

### 1.2 pg_repack —— 在线重建，回答「怎么把空间收回来」

- 第三方扩展（PGDG 打包），做的事等价于 `VACUUM FULL` / `CLUSTER`，但**几乎全程不阻塞业务读写**。
- 原理：建日志表记录变更 → 按原表建一份新表并灌数据 → 回放日志 → 短暂拿 ACCESS EXCLUSIVE 锁交换文件节点。
  只有起止两个瞬间需要排他锁。
- 与 `VACUUM FULL` 的取舍：

| | pg_repack | VACUUM FULL |
|---|---|---|
| 阻塞 | 起止各一次短暂排他锁 | 全程排他锁，读写都挡 |
| 前提 | 表必须有主键或非空唯一索引 | 无 |
| 临时空间 | 约一份表 + 索引 | 约一份表 + 索引 |
| 需要装包 | 是（OS 包 + 扩展） | 否 |
| 适用 | 生产在线压缩 | 小表低峰、或没法装包 |

- 不能 repack 的对象：无主键 / 唯一索引的表、临时表、TimescaleDB 的 hypertable 本身（只能按 chunk 压）。
- 不进 `shared_preload_libraries`，装完不用重启 PostgreSQL。

## 2. 前置检查（只读，任何客户端都可跑）

```sql
-- ① 包装了没、扩展建了没
SELECT name, default_version, installed_version
FROM pg_available_extensions WHERE name IN ('pg_repack', 'pgstattuple');
-- 没有 pg_repack 行 ⇒ OS 包没装，走第 3 节
-- 有行但 installed_version 为空 ⇒ 只差 CREATE EXTENSION，走第 4 节

-- ② 目标表有没有主键（pg_repack 硬性要求）
SELECT conname FROM pg_constraint
WHERE conrelid = 'iot.node'::regclass AND contype = 'p';

-- ③ 表与索引的物理大小，据此估临时空间；两者之比也是判据（见第 5 节）
SELECT pg_size_pretty(pg_table_size('iot.node'))   AS table_size,
       pg_size_pretty(pg_indexes_size('iot.node')) AS index_size;

-- ④ 全部索引定义 + 当前按表参数 —— 决定 fillfactor 怎么设，MUST NOT 假设是全局默认
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'iot' AND tablename = 'node';
SELECT reloptions FROM pg_class WHERE oid = 'iot.node'::regclass;

-- ⑤ 当前 HOT 比例 —— 压前基线，压后拿它判 fillfactor 够不够
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0*n_tup_hot_upd/nullif(n_tup_upd,0),1) AS hot_pct
FROM pg_stat_user_tables WHERE schemaname = 'iot' AND relname = 'node';

-- ⑥ 有没有长事务 —— pg_repack 起止要拿 ACCESS EXCLUSIVE 锁，撞上长事务会等或杀会话
SELECT pid, state, now()-xact_start AS xact_age, now()-state_change AS idle_age,
       left(query,60) AS q
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND backend_type = 'client backend'
ORDER BY xact_start LIMIT 10;
```

数据盘剩余空间必须大于 `table_size + index_size`。

⑥ 出现 `idle in transaction` 且 `idle_age` 上分钟的 ⇒ **先查清它的来源再 repack**。
那既是 repack 会被挡住的原因，也往往就是表膨胀的原因本身（长快照挡住 HOT 剪枝，旧版本不能就地回收）。
注意这条只是瞬时采样，干净不代表没有偶发长事务——它是 repack 的前置，不是机制的结论。

## 3. 安装 OS 包（root，在数据库服务器上）

> **本节所有命令都要 root。** 本仓的服务器一律禁 root 直登，登进去是普通用户，
> 直接跑 `apt-mark` / `apt-get` 会报 `required read/write access to the dpkg database directory /var/lib/dpkg`。
> **先 `sudo -i` 切到 root shell，本节命令即可原样照跑**；不想切就每条前面加 `sudo`
> （注意 `apt-get install -s ... | grep` 这种带管道的，sudo 只加在 `apt-get` 上，管道后半段不需要）。

> ⚠️ **Debian 系装完包可能弹 needrestart 的「Daemons using outdated libraries」对话框，
> `postgresql@<N>-main` / `pgbouncer` / `redis-server` 默认是勾选的——直接回车就重启生产库。**
> 它跟你装的包无关，列的是之前某次共享库（libssl / libc）升级后还在用旧 so 的进程，每次跑 apt 都问一遍。
> 处置：`<Cancel>` 回车（什么都不重启，包照样装完），或用 ↑↓ + 空格取消这几项勾选再 `<Ok>`。
> 一劳永逸：`echo '$nrconf{restart} = "l";' > /etc/needrestart/conf.d/pg-ops.conf`
> （list only，以后只打印不重启；写 `conf.d/` 不动发行版托管的主配置）。
> Ubuntu 24.04 引入的 "Ubuntu mode" 曾让这个开关失效，`needrestart 3.6-7ubuntu4.1` 起修复，
> 24.04+ 上配完 MUST 用 `needrestart -b | grep NEEDRESTART-SVC` 实测一次确认它只列不重启。

pg_repack 客户端二进制与扩展 SQL 文件在同一个包里，版本必须一致；从同一个包装就不会错。
PG 16 需要 pg_repack ≥ 1.5.0，PGDG 源里的版本满足。

先看发行版：

```bash
head -3 /etc/os-release
```

**先说风险**：`apt-get update` 只刷新索引，不会升级任何包、不会重启服务。风险在 `apt-get install`：
它会拉依赖，若源里有更新的 `postgresql-16` 小版本且被判定需要，Debian 系的 postgresql 包升级时 postinst 会重启集群。
PGDG 的 repack 包对 `postgresql-16` 通常不锁版本，已装版本即可满足，但生产上用下面两道保险，不靠「通常」。

### Ubuntu / Debian（PGDG apt 源）

```bash
# ① 锁住 PG 本体：apt 无法升它，依赖它的 timescaledb 等包也不会被连带动。生产机建议长期 hold，PG 升级另开窗口
apt-mark hold postgresql-16 postgresql-client-16 postgresql-common

# ② 刷索引 + 模拟安装，看 Inst / Conf / Remv 行是不是只有 repack 一个包
apt-get update
apt-get install -s postgresql-16-repack | grep -E '^(Inst|Conf|Remv)'

# ③ 模拟结果只含 repack 才真装（换成实际大版本号）
apt-get install -y postgresql-16-repack
```

模拟输出出现 `Inst postgresql-16` ⇒ 源里的 repack 包要求更新的 PG 版本，hold 会让 apt 报依赖失败而不是偷偷升级，
这时单独安排 PG 小版本升级窗口，不要解 hold 硬装。

若还没配 PGDG 源：

```bash
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
# 国内机器官方源极慢，把 /etc/apt/sources.list.d/pgdg.sources 的 URIs: 换成镜像后再 apt-get update
```

### RHEL / Rocky / Alibaba Cloud Linux（PGDG yum 源）

```bash
# 先看事务清单，确认只装 pg_repack_16；再排除 PG 本体真装
dnf install --assumeno pg_repack_16
dnf install -y --setopt=exclude=postgresql16\* pg_repack_16    # 换成实际大版本号
```

装完确认：

```bash
pg_repack --version
```

## 4. 建扩展（超级用户，直连 PostgreSQL 端口，不要经 PgBouncer）

扩展按库生效，在要压的表所在库里建：

```sql
\c ddl
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS pg_repack;
```

## 5. 量化膨胀

```sql
SELECT pg_size_pretty(table_len) AS size,
       tuple_percent, dead_tuple_percent, free_percent
FROM pgstattuple('iot.node');
```

记下数字，压完后对比。三种形态判然不同，**别只看一个数**：

| 形态 | 含义 | 该做什么 |
|---|---|---|
| `dead_tuple_percent` 高 | vacuum **现在**就跟不上写入 | 调 vacuum 参数有用；repack 之后还会再涨 |
| `dead` 低 + `free_percent` 极高 | 死元组已清干净，**只是文件缩不回去**（存量膨胀） | **调 vacuum 参数一点用没有**，只有 repack / VACUUM FULL 能收 |
| 两者都低、`tuple_percent` 高 | 表是健康的 | 不用 repack，去别处找问题 |

再配合前置检查 ⑤⑥ 交叉验证机制：**堆膨胀了千倍而索引几乎没膨胀、且 `hot_pct` 高 ⇒ HOT 在正常工作**，
可以直接排除「更新打散到别的页 + 索引垃圾堆积」这条最常见的剧本，去查长快照 / 长事务。

## 6. 防复发参数（MUST 在下一节 repack 之前设）

repack 只回收存量，根因不处理会复发。按表设置：

```sql
SET lock_timeout = '3s';          -- 与下面 ALTER 同一会话；避免排在长查询后面把业务挡住
ALTER TABLE iot.node SET (
  autovacuum_vacuum_scale_factor = 0,
  autovacuum_vacuum_threshold    = 1000,
  autovacuum_vacuum_cost_delay   = 0,
  fillfactor                     = 70
);
SELECT reloptions FROM pg_class WHERE oid = 'iot.node'::regclass;   -- 确认落上了
```

`ALTER TABLE ... SET (...)` 只改 catalog、不重写数据，瞬时完成；但要一把短的 ACCESS EXCLUSIVE 锁，
所以配 `lock_timeout`。报 `lock_timeout` 就过一会儿重试，**不要去杀会话**。

### fillfactor 的因果容易搞反

教科书说法是「fillfactor 留空位让更新走 HOT」。**在一张已经膨胀的表上，这个因果是反的**：

- 膨胀表里到处是空洞（`free_percent` 极高），页上永远有空位，所以 `hot_pct` 往往已经很高——
  这是膨胀的副产物，不是健康的表现；
- repack 会把页压到 100% 填满，**HOT 率反而会掉下去，表就重新开始长**；
- 所以 `fillfactor = 70` 的真实作用是**保住 repack 之前那个 HOT 率**，不是获得 HOT。

由此有两条硬顺序：**先设 fillfactor 再 repack**（只对新页生效），
以及**压前必须先记下 `hot_pct`**（第 2 节 ⑤），否则压完没有基线可比。

前提仍要确认：fillfactor 能让更新走 HOT，要求**被高频更新的那些列上没有索引**（第 2 节 ④）。
有索引则每次更新都要连带写索引、走不了 HOT，fillfactor 只是白占 30% 空间——
这时先判断那个索引能不能删，删不掉就别设 fillfactor。

## 7. 执行 pg_repack（在数据库服务器上跑，选业务低峰）

```bash
pg_repack -h 127.0.0.1 -p 5432 -U postgres -d ddl -t iot.node --wait-timeout 60
```

> **pg_repack 成功时只在开头打一行 `INFO: repacking table "<表>"`，收尾什么都不打。**
> 所以 `tail -f` 看着像卡住是正常的，MUST NOT 因为「没输出」就去 kill 它。
> 判断它到底在不在跑，用下面「怎么看进度」那三条查询。

**生产上挂后台跑，别让 SSH 断线打断换文件节点那一步**：

```bash
nohup pg_repack -h 127.0.0.1 -p 5432 -U postgres -d ddl -t iot.node --wait-timeout 60 \
  > /var/log/pg-repack-<表名>.log 2>&1 &
tail -f /var/log/pg-repack-<表名>.log     # Ctrl-C 随便按，repack 在后台照跑
```

用 tmux 也行；本机终端是 ghostty / kitty 这类新终端时服务器上没有对应 terminfo，会报
`missing or unsuitable terminal`，前面加 `TERM=xterm-256color` 即可（或 `infocmp -x $TERM | ssh <host> 'tic -x -'` 装一次）。

参数说明：

- `-t schema.table`：只压这一张表；`-d` 是库名。压整库去掉 `-t`，不建议在生产一次压全库。
- `--wait-timeout 60`：起止拿排他锁时最多等 60 秒；超时后 pg_repack 会取消挡路的会话，再等不到就自己退出。
  不想它取消别人的会话加 `--no-kill-backend`。
- `-j N`：多个索引并行重建，CPU 有余量时可加。
- `--dry-run`：只打印不执行，第一次跑先看一遍。
- 默认要求超级用户，普通用户加 `-k` 跳过检查，但需要该用户是表 owner。

### 怎么看进度（它自己不打进度）

另开一个会话查：

```sql
-- ① repack 的连接在做什么、在等什么
SELECT pid, application_name, state, wait_event_type, wait_event,
       now()-query_start AS dur, left(query,80) AS q
FROM pg_stat_activity WHERE application_name = 'pg_repack' ORDER BY query_start;

-- ② 有没有被别人挡住
SELECT pid, pg_blocking_pids(pid) AS blocked_by, wait_event, left(query,60) AS q
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;

-- ③ 进度：它建的新表长到多大了
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS sz
FROM pg_class WHERE relnamespace = 'repack'::regnamespace ORDER BY relname;
```

| 现象 | 含义 |
|---|---|
| ① 是 `INSERT INTO repack.table_...` 或 `wait_event_type = IO`，③ 里 `table_<oid>` 在变大 | 正在拷数据，等着就行 |
| ① `wait_event_type = Lock` | 在等锁，看 ② 是谁挡的 |
| **三条全空**（①② 无行，③ 只剩 `primary_keys` / `tables` 两个扩展自带的视图，0 bytes） | **已经跑完并清理干净了**，不是卡住——去查表大小确认 |

最后一行是实践中最容易误判的：它和「还没开始」长得一样。区分办法是直接看
`pg_table_size('<表>')` 掉了没有，或者 `ps -ef \| grep [p]g_repack` 看进程还在不在。

另外 repack 在开工前要等所有比它早开始的事务结束，有老事务时会在这里干等，② 能看出来。

跑完立即验证：

```sql
SELECT pg_size_pretty(pg_table_size('iot.node'));
SELECT tuple_percent, dead_tuple_percent, free_percent FROM pgstattuple('iot.node');
```

预期表大小与行数 × 行宽同量级。`tuple_percent` 的预期取决于 fillfactor：没设就是 90% 以上；按第 6 节设了 `fillfactor = 70`，则**预期就是 65~70%**——那 30% 是留给 HOT 的空位，不是没压干净。

## 8. 压完盯几天

存量收回是确定的，防复发不是——机制没查清之前，唯一的判别手段是观察：

```sql
-- 连续几天每天记一次
SELECT now() AS ts, pg_table_size('iot.node') AS tbl_bytes,
       n_tup_upd, n_tup_hot_upd
FROM pg_stat_user_tables WHERE schemaname = 'iot' AND relname = 'node';
```

⚠️ **`n_tup_upd` / `n_tup_hot_upd` 是自统计重置以来的累计值**，repack 不重置它们。
在一张已经被更新过上亿次的表上直接算 `hot_pct` 会被历史数淹没、看不出任何变化——
**MUST 用两次采样的差算区间值**：

```
区间 hot_pct = (本次 n_tup_hot_upd − 上次 n_tup_hot_upd)
             / (本次 n_tup_upd     − 上次 n_tup_upd    ) × 100
```

- **区间 `hot_pct` 掉到 90% 以下** ⇒ fillfactor 不够，往 60 / 50 调（活数据小的表，这点空间代价可忽略）；
- **表大小又开始按天涨** ⇒ 多半是长快照挡住 HOT 剪枝，去查 `idle in transaction` 的来源，
  并设 `idle_in_transaction_session_timeout`（生产必设）；
- 两者都稳 ⇒ 收工。

## 9. 失败与回退

- pg_repack 中途失败会留下 `repack` schema 下的日志表和触发器，用 `pg_repack` 同参数再跑一次会自动清理；
  或手动 `DROP EXTENSION pg_repack; CREATE EXTENSION pg_repack;`。
- 没法装包时的备选：低峰 `VACUUM FULL iot.node;`，全程排他锁，万行级小表一分钟内完成。
- 表没有主键：先加主键或非空唯一索引，否则只能 `VACUUM FULL`。

## 10. 一次完整流程速查

节的顺序就是执行的顺序，照着往下走即可：

1. **第 2 节** 六条只读查询：包 / 主键 / 空间 / 索引与 reloptions / HOT 基线 / 长事务。
2. **第 3 节** 装包（⚠️ 留意 needrestart 弹框，别回车重启生产库），**第 4 节** 建扩展。
3. **第 5 节** 记下压前数字，按三形态表判断该不该压。
4. **第 6 节** 设按表参数——`fillfactor` 只对新页生效，**必须早于 repack**。
5. **第 7 节** 低峰 repack（挂 nohup / tmux），压完立即验证。
6. **第 8 节** 连续几天盯表大小与 `hot_pct`，确认没复发。

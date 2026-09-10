# Runbook：PostgreSQL 16 → 18 大版本升级（pg_upgrade 原地）

> 2026-09-05 起草。参照场景：一台 PG 16、约 1.1 TB、19 个库、装有 TimescaleDB 的云主机。
> 本文是人读 runbook，不含项目参数；库名 / 路径按实际替换。
> 结论先行：**有价值但不急**。先做 case 文档的 #1～#5，再单独排窗口。

## 1. 值不值得升

### 1.1 升级能带来什么（按这台机器的负载排序）

| 版本 | 特性 | 对这台的意义 |
|---|---|---|
| 17 | vacuum 死元组集合改用 TidStore，内存占用降约 20 倍，vacuum 更快 | 1.1 TB 库的 autovacuum 跟不上是核心矛盾之一 |
| 18 | 异步 I/O（`io_method = worker`），顺序扫描 / vacuum / bitmap 扫描吞吐更高 | 数据全在 ESSD 云盘，直接受益 |
| 18 | B-tree skip scan：复合索引前导列不在条件里也能用索引 | 少建冗余索引 |
| 18 | pg_upgrade 保留优化器统计信息 | 升完不用等 ANALYZE 跑几小时，缩短「升完变慢」窗口 |
| 17 | `pg_basebackup` 增量备份 | 生产备份方案（pgBackRest 之外）多一个选项 |
| 18 | `uuidv7()`、虚拟生成列、`RETURNING OLD/NEW` | 开发便利，与生产性能无关 |
| — | 与本仓「开发 = 生产大版本」约束对齐 | 开发库已是 18 |

### 1.2 为什么不急

- PG 16 社区支持到 **2028-11**，没有安全或 EOL 压力。
- 当前 CPU 锯齿的根因（表膨胀、JIT、函数体缺索引）升级版本一个都不解决。
- ~~TimescaleDB 是硬约束（见 §2.1），可能把一次窗口变成两次。~~ 2026-09-05 已确认无库安装，此项不成立。

## 2. 前置条件（不停服）

### 2.1 TimescaleDB 版本 —— 决定一次窗口还是两次

- PG 18 需要 **TimescaleDB ≥ 2.23**。
- pg_upgrade 要求**新旧集群的 TimescaleDB 版本完全相同**；TimescaleDB 官方明确：不能同时升 PG 与 TimescaleDB。
- 因此若当前 < 2.23，得先在 16 上 `ALTER EXTENSION timescaledb UPDATE`，它在 `shared_preload_libraries` 里，需要一次重启 ⇒ 单独一个小窗口。

```sql
SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';
```

**先确认它到底用没用。** `pg_extension` 是每库一份的目录表，没有跨库的一条 SQL，要逐库查。

有服务器 shell 时，一段循环跑完所有库：

```bash
sudo -u postgres bash -c '
for db in $(psql -Atc "SELECT datname FROM pg_database WHERE datallowconn AND datname NOT IN ('"'"'template0'"'"','"'"'template1'"'"')"); do
  v=$(psql -d "$db" -Atc "SELECT extversion FROM pg_extension WHERE extname = '"'"'timescaledb'"'"'")
  if [ -n "$v" ]; then
    n=$(psql -d "$db" -Atc "SELECT count(*) FROM timescaledb_information.hypertables")
    echo "$db: timescaledb $v, hypertables=$n"
  else
    echo "$db: 未装"
  fi
done'
```

只有 SQL 客户端（Navicat）时，先列库名，再逐库切换跑第二条（没装的库也不会报错）：

```sql
SELECT datname FROM pg_database
WHERE datallowconn AND datname NOT IN ('template0', 'template1');

SELECT current_database() AS db,
       (SELECT extversion FROM pg_extension WHERE extname = 'timescaledb') AS ts_version,
       to_regclass('_timescaledb_catalog.hypertable') IS NOT NULL AS ts_installed;
```

`ts_installed` 为 true 的库再跑：

```sql
SELECT count(*) FROM timescaledb_information.hypertables;
```

所有装了的库 `hypertables = 0` ⇒ 全部「装了没用」。

- **没有 hypertable** ⇒ 在 16 上直接 `DROP EXTENSION timescaledb;`（普通 DDL，不停服、不重启），
  18 不装 `timescaledb-2-postgresql-18`，§3.1 的版本一致约束与「两次窗口」风险都消失。
- **有 hypertable** ⇒ 走上面的版本一致路线，MUST NOT drop（会连表一起删）。

**2026-09-05 实测结论：16 个库全部「未装」**，timescaledb 只挂在 `shared_preload_libraries` 里空转，连 DROP EXTENSION 都不需要。
剩下唯一要做的：**升级前把它从 16 的配置里去掉**。`pg_upgradecluster` 会把 16 的配置拷给 18，preload 里留着 `timescaledb`
而 18 没装对应的 .so，18 集群在 pg_upgrade 过程中会启不起来。改配置不用立刻重启，升级窗口的停机自然生效。

```bash
grep -rn shared_preload_libraries /etc/postgresql/16/main/     # 找到写在哪个文件
# 把 timescaledb 从列表里删掉，只留 pg_stat_statements
```

### 2.2 扩展清单 —— 每个库都要有 18 的包

19 个库各跑一次，汇总去重后逐个确认 PGDG 有 `postgresql-18-<ext>`：

```sql
SELECT extname, extversion FROM pg_extension ORDER BY 1;
```

`pg_stat_statements`、`pgstattuple` 是 contrib，随 `postgresql-18` 自带；`pg_repack` 装 `postgresql-18-repack`。

### 2.3 数据校验和 —— pg_upgrade 要求两边一致

PG 18 的 initdb **默认开启**数据校验和，16 集群多半没开。先查：

```sql
SHOW data_checksums;
```

为 `off` 时，新集群 initdb 必须传 `--no-data-checksums`，否则 `--check` 会报不一致。

### 2.4 磁盘与表空间

- `--link` 模式不复制数据文件，不需要第二份空间；只需 catalog 与 WAL 的少量空间。
- 表空间 `ts_data2`（`/data2/pgdata`）pg_upgrade 会自动处理，在同一路径下新建 `PG_18_*` 子目录。

## 3. 升级步骤

### 3.1 并存安装（不停服）

```bash
apt-mark hold postgresql-16 postgresql-client-16      # 防 16 被连带升级重启，见 runbook-pg-repack.md §3
apt-get update
apt-get install -s postgresql-18 postgresql-18-repack | grep -E '^(Inst|Conf|Remv)'
apt-get install -y postgresql-18 postgresql-18-repack
```

仅当 §2.1 确认 TimescaleDB 在用时才加装 `timescaledb-2-postgresql-18`，且版本必须与 16 上的完全一致，装前用 `apt-cache policy` 核对；不一致就指定版本号装。
Debian 系装 `postgresql-18` 会自动建一个空的 `18/main` 集群，`pg_upgradecluster` 会先删掉它再建新的，或手动 `pg_dropcluster 18 main`。

### 3.2 快照（不停服，唯一可靠的回滚手段）

阿里云控制台对系统盘、`/dev/vdb`（pgdata）、`/dev/vdc1`（pgdata2）各打一份快照。ESSD 快照分钟级，不影响运行。

### 3.3 预检（不停服，旧库运行中即可跑）

```bash
pg_upgradecluster -m upgrade --link --check 16 main
```

或直接调 pg_upgrade（路径按 Debian 布局）：

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_upgrade \
  -b /usr/lib/postgresql/16/bin -B /usr/lib/postgresql/18/bin \
  -d /etc/postgresql/16/main -D /etc/postgresql/18/main \
  --link --check
```

报错项逐个消掉再进窗口。常见的三类：preload 里残留 18 没装的库（本机的 timescaledb，见 §2.1）、校验和不一致、某个扩展 18 没装。

### 3.4 停服窗口

```bash
# 1. 挡住新连接：PgBouncer 暂停（session 模式下等现有会话跑完）
psql -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'

# 2. 停 16
systemctl stop postgresql@16-main

# 3. 升级（--link 硬链接；PG 18 新增 --swap 更快，但 pg_upgradecluster 尚未封装，用则直接调 pg_upgrade）
pg_upgradecluster -m upgrade --link 16 main

# 4. 复核配置：conf.d/90-pg-ops.conf、shared_preload_libraries、端口、pg_hba，然后启 18
systemctl start postgresql@18-main

# 5. 补扩展统计（普通统计已保留，只补缺的）
sudo -u postgres vacuumdb --all --missing-stats-only --analyze-in-stages

# 6. PgBouncer 放行
psql -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'
```

`pg_upgradecluster` 会把 16 的端口给 18、16 改到 5433，PgBouncer 指向 5432 不用改。

### 3.5 验证与清理

- 业务侧确认读写正常，`pg_stat_statements` 看 top 语句耗时与升级前同量级。
- 观察几天后删旧集群：`pg_dropcluster 16 main`。
- `--link` 模式下 **18 一启动，16 集群就不能再用**（文件被两边共享且 catalog 已改），回滚只能靠 §3.2 的快照。

## 4. 停服时长

| 方式 | 停服 | 判定 |
|---|---|---|
| `pg_upgrade --link` / `--swap` | 实际 10～20 分钟；窗口报 30～60 分钟 | **推荐**。耗时取决于 19 个库的 catalog 对象数，与 1.1 TB 数据量无关 |
| `pg_dumpall` 导出导入 | 数小时（1.1 TB 传输 + 重建索引） | 不用 |
| 逻辑复制切换 | 接近零，但初始同步 1.1 TB 要数小时，且 TimescaleDB hypertable 对逻辑复制支持有限 | 不值得 |

## 5. 与本仓规划的关系

- 规划中的 `pg-prod-server` 直接装 18（见 `docs/skills-roadmap.md`），新生产库不涉及本文。
- 本文只服务**存量 16 生产机**。若它与新生产库同属一个项目，按「开发 = 生产大版本」应升；若是独立系统，按 §1 判断。
- 升级窗口宜排在 case 文档 #1～#5 落地并观察稳定之后，避免两组变量叠在一起分不清效果。

## 6. 参考

- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/release/18.0/) —— 异步 I/O、skip scan、pg_upgrade 保留统计、`--swap`、校验和默认开启
- [PostgreSQL 18: pg_upgrade](https://www.postgresql.org/docs/current/pgupgrade.html) —— `--link` / `--swap` / `--check` 语义与限制
- [CYBERTEC: Optimizer statistics preserved during upgrade in PostgreSQL v18](https://www.cybertec-postgresql.com/en/preserve-optimizer-statistics-during-major-upgrades-with-postgresql-v18/)
- [Fujitsu: Enhancements to pg_upgrade in PostgreSQL 18](https://www.postgresql.fastware.com/pzone/enhancements-to-pg-upgrade-in-postgresql-18)
- [Tiger Data: Upgrade PostgreSQL（TimescaleDB 场景）](https://www.tigerdata.com/docs/deploy/self-hosted/upgrades/upgrade-pg) —— 新旧 TimescaleDB 版本必须相同，不能同时升两者
- [TimescaleDB CHANGELOG](https://github.com/timescale/timescaledb/blob/main/CHANGELOG.md) —— 2.23 起支持 PG 18
- [PostgreSQL Versioning Policy](https://www.postgresql.org/support/versioning/) —— PG 16 支持到 2028-11

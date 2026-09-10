# pg-ops 快速上手（给人读）

本页讲的是**人该做什么、该说什么、会得到什么、东西落在哪**。各 skill 的 `SKILL.md` 是给 Claude / Codex 读的操作手册，
人不必看；本页按三种场景组织，照着走即可。前提是本机已按 README「安装」装好 pg-ops（`~/.skills/pg-ops` + `setup.sh`）。

## 先记住一张图：两处目录，一处真相

```
 开发机：项目仓根 .pg-ops/（整个目录 gitignore + deny）  服务器：/opt/pg-ops/（root 700，真相源）
 +------------------------------------------+         +---------------------------------------------+
 | pg-dev-server.env   服务器参数（ssh 别名等）|         | handover.md        服务器交接文档（含口令）   |
 | pg-dev-init.env     本项目建库参数（库名）  |  scp   | projects/<库名>.md  各项目库的账号与连接串     |
 | build/*.sh          渲染出的自包含脚本      | -----> | bin/               装机 / 建库脚本，可原地重跑 |
 | handover.md         服务器交接文档副本      | <----- | bin/diag/          只读诊断脚本               |
 | projects/<库名>.md  本项目库交接文档副本    |pgops-fetch.sh| postgres.pass  超级用户网络口令           |
 +------------------------------------------+         +---------------------------------------------+
```

- 口令在服务器首次生成、之后沿用，**开发机不保存口令**，副本只是取回给项目管理者看的。
- 每个项目仓各自记自己的 dev server；同一台服务器被多个项目共用时互不影响。
- 想知道任何事，用 `<skill-dir>/scripts/pgops-fetch.sh <host> <远端路径>` 取回到本地文件再看
  （不用重跑脚本；模型不会把内容打进回复——`pgops-env.sh` / `pgops-fetch.sh` / `pgops-guard.sh` 三个工具脚本的
  stdout 只打路径与非口令单值，人自己 `cat` 取回的文件，或登录服务器亲自 `sudo cat`）。

## 场景 A：搭一台新的开发数据库服务器（`/pg-dev-server`）

**什么时候**：新开一台 Ubuntu 机器做开发库（与生产物理分离）。一台服务器只装一次，之后每个项目各自建库（场景 B）。

**怎么说**：在**任一项目仓根目录**（推荐就是第一个要用它的项目）对 Claude / Codex 说：

> 搭一台开发数据库服务器，ssh 别名是 `dev`

**会被问什么**（只问人才知道的，其余取默认）：

| 问 | 为什么问你 | 缺省 |
|---|---|---|
| 机器规格（核 / 内存） | 定 swap、shared_buffers、Redis maxmemory | 按 2 核 2G |
| 生产 PG 大版本 | 开发库 MUST 与生产一致 | 18 |
| 数据放哪块盘 | 有没有独立数据盘只有你知道 | `/data`；没有就留空用 `/var/lib` |
| SSH 来源白名单 | 办公网出口 IP | 留空 = 靠密钥 + fail2ban |
| 机器在不在国内 | 决定 PGDG 镜像 | 国内填 aliyun 镜像 |
| 公网 IP | 只用于交接文档里的安全组说明 | — |

**会发生什么**：

1. 项目仓根落 `.pg-ops/pg-dev-server.env`（自动确认 `.pg-ops/` 已 gitignore），渲染出 `.pg-ops/build/install-<host>.sh`。
2. **默认打印两行命令由你上服务器执行**（scp + `ssh -t ... sudo bash`）。你明确说「你来跑」它才会代跑并把输出带回。
3. 脚本装 PostgreSQL + PgBouncer 两实例（6432 transaction / 7432 session）+ Redis，全部只监听 127.0.0.1；
   探活全过才算完成，失败会非零退出、不会假绿；末尾跑一次连接自检。
4. 服务器写 `/opt/pg-ops/handover.md`，开发机取回副本 `.pg-ops/handover.md`。

**装完你还要做的**（脚本不碰这两样）：

- **加固**：说「跑一下加固」→ 同一份 env 渲染 `harden-<host>.sh`，做 sshd 只密钥 / root 禁登 / ufw 只放 22 / fail2ban / 自动安全更新。
  **跑完另开一个 ssh 会话确认能登录，当前会话别关**；登不上在原会话回滚（命令在 SKILL.md ⑤）。
- **云安全组**：控制台入方向只留 22，照交接文档第 4 节 ① 做。

## 场景 B：给一个项目立 PG 开发环境（`/pg-dev-init`）—— 最常见

**什么时候**：项目首次接开发库。服务器装没装过都行：装过就只接入，没装过它会先走场景 A 再建库。

**怎么说**：在**该项目仓根目录**说：

> 给这个项目建 pg dev 环境，服务器是 `dev`

只有**库名**一项要你确认。它会先推一个提议并说明来源（依次看 `go.mod` module 名 / `package.json` name / 项目现有 dev 配置 / 目录名，
连字符转下划线，规则 `[a-z_][a-z0-9_]*`），不合意直接改。
用户名默认同库名，口令默认服务器自动生成，另建一个 `<库名>_scratch` 可炸的空库排练迁移（不要就说 `none`）。

两项按需才填：
- **`CREATEDB`**：要让这个角色自己 `CREATE`/`DROP` 测试克隆库（如集成测试每次建一个临时库）才说，默认不给（幂等，不收回已给的）。
- **`REDIS_DB`**：默认自动分配（同服务器上第一个没被别的项目占用的编号，换密重跑沿用文档里已分配的号）；
  要钉死某个编号（如迁移一个已在用某个 db 号的旧项目）才说明确数字，`0` 保留给人手工探查不可用。

**会发生什么**（pg-dev-init 自己调用 pg-dev-server 做前置检查，你只说一次）：

```
 /pg-dev-init：项目仓没有 .pg-ops/pg-dev-server.env => 调 /pg-dev-server 做起手判断
        |            ssh <host> sudo test -f /opt/pg-ops/handover.md
        |
        +-- INSTALLED（服务器装过）=> 不重装。只落 .pg-ops/pg-dev-server.env + 取回 .pg-ops/handover.md，返回
        +-- FRESH（没装过）        => 走场景 A 装机，装好再返回
        |
        v
 渲染 .pg-ops/build/db-<库名>.sh => 打印 scp + ssh 两行（或你说「你来跑」）
        |
        v
 服务器：建角色 / 建库 / 建 scratch 库 => 经 PgBouncer 真登录探活 => 写 /opt/pg-ops/projects/<库名>.md
        |
        v
 开发机：取回副本 .pg-ops/projects/<库名>.md（含口令，600）
```

重跑幂等：库已存在不碰数据，口令不动。角色经 PgBouncer `auth_query` 自动可登录，**项目侧零 PgBouncer 配置**。

**做完你拿到的**：`.pg-ops/projects/<库名>.md`，里面有账号、口令和三个端口的连接串：

| 端口 | 用在 | 注意 |
|---|---|---|
| 6432（transaction 池，**默认**） | 应用运行时、集成测试 | 事务之间不保证同一服务端连接：`SET` 会话变量、`LISTEN`、会话级 advisory lock、逻辑复制不可靠。**lib/pq（含 GoFrame `pgsql` 驱动）连接串 MUST 加 `binary_parameters=yes`**，否则报 `unnamed prepared statement does not exist` |
| 7432（session 池） | 要会话级特性又想经池子 | 池更贵，别当默认 |
| 5432（直连） | 迁移、`pg_restore`、DB 工具 | 超级用户 `postgres` 只能走这里，两个池口都拒绝它 |

**然后归项目自己**（pg-ops 不做，只提示）：

1. 口令收进项目 secret 工具；**项目 dev 配置里的库名 / 用户 / 口令换成这套新账号**，别再用 `postgres`（两个池口都拒绝超级用户）。
2. 起隧道。命令在 `.pg-ops/handover.md` 第 3 节，形如：

```bash
ssh -N -L 5432:127.0.0.1:5432 -L 6432:127.0.0.1:6432 -L 7432:127.0.0.1:7432 -L 6379:127.0.0.1:6379 <host>
```

隧道起来后，开发机上的连接串与服务器侧完全相同（`127.0.0.1:<同端口>`）。

3. 跑项目自己的迁移 / init。

应用侧连接池怎么配（池上限、idle = open、lifetime 带单位、`application_name`）见 `handover.md`「应用侧连接池契约」。

## 场景 C：日常——换密 / 查账号 / 刷新文档

| 想做 | 怎么说 / 怎么做 | 结果 |
|---|---|---|
| 换某项目库的口令 | 在项目仓说「给开发库换密」，把新口令填进 `.pg-ops/pg-dev-init.env` 的 `DB_PASS` 重渲染重跑 | 角色改密，`projects/<库名>.md` 随之更新 |
| 这个项目的库账号是什么 | `bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/projects/<库名>.md`，取回后自己 `cat`；或登录服务器亲自 `sudo cat` | 含口令，走安全渠道传；模型不会把内容打进回复 |
| 这台机上有哪些项目库 | `ssh <host> sudo ls /opt/pg-ops/projects/` | 不含口令，可直接打进回复 |
| 服务器信息 / Redis 口令 / 隧道 / 安全清单 | `bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/handover.md`，取回后自己 `cat`；或登录服务器亲自 `sudo cat` | 模型不会把内容打进回复 |
| 交接文档模板升级了，只想刷新文档 | 说「只重生成交接文档」→ `PG_OPS_DOCS_ONLY=1`，不装包不改配置不重启 | 服务器与副本都更新 |
| 调服务器参数（swap / shared_buffers / Redis maxmemory） | 改 `.pg-ops/pg-dev-server.env` 重渲染重跑装机脚本 | 幂等；PG 配置没变不重启 |
| 服务器上的脚本想原地重跑 | `sudo bash /opt/pg-ops/bin/<脚本>.sh` | 脚本执行时已自装到 bin/，不用再上传 |
| 排查连接 / CPU 问题 | `sudo /opt/pg-ops/bin/diag/pg-conn-audit.sh 5`、`sudo /opt/pg-ops/bin/diag/pgb-console.sh` | 只读诊断，说明见 `bin/diag/README.md` |

## 场景 D：从生产拉一份快照到开发库（`/pg-sync`）

**什么时候**：开发库的 schema 或数据落后生产太久，光跑迁移脚本对不上；或者要用生产真实数据量排查一个
只在真实数据规模下才复现的问题。

**怎么说**：在项目仓根说：

> 从生产拉快照到开发库

**会被问什么**（只问人才知道的，其余取默认）：

| 问 | 为什么问你 | 缺省 |
|---|---|---|
| 传输走 rsync 还是 OSS | 生产和 dev 网络能不能直接互通只有你知道 | 无——两条路线二选一，人明确说 |
| 生产库名 / dev 目标库名 | 生产库名可能和项目 dev 库名不同 | dev 库名沿用 `pg-dev-init` 已建的库 |
| 要不要裁剪数据（`DATA_RULES`） | 哪些表要按时间窗口裁剪、哪些整表跳过，只有你知道 | `* full`（整库全量，宁可多同步不漏同步） |

**边界（先说清楚）**：模型只生成开发机 `pg-sync.env`（不含任何生产敏感值）和渲染产物；**模型不读生产 env、
不登生产机、也不看生产机的任何输出**——身份核对、锁槽账、磁盘账全部由脚本在生产机上自己判断（ADR-0001）。
生产侧的每一步都由**人**在生产机上亲自执行。

**会发生什么**（两阶段：schema 先行，data 随时可重跑）：

```
 一次性准备（选一条传输路线）：
   rsync：生产首跑出公钥 → 人贴进 dev 机 receive-setup → dev 打印主机公钥 → 人贴回生产 env
   OSS  ：人在控制台建 bucket + 只写/只读两个 RAM 子账号 → 两机各自 ossutil config

 schema 阶段（生产机，人跑）              →  传输  →   dev 机（人跑，或说「你来跑」委托）
 00-inventory（首跑打印 system_identifier）        receive-setup / fetch-oss（收 + sha256 校验）
        |                                                    |
 10-dump-schema（身份核对→pg_dump --schema-only→指纹→manifest）  restore-schema（建 <库>_sync→装 schema→sync.json）

 data 阶段（同一份 00-inventory 解出 plan.tsv，可反复跑）
 20-dump-data（full=-Fd 清单 / window=逐表 COPY → manifest）  →  restore-data（装载→setval→ANALYZE→钩子→rename 切换）
```

**拿到什么**：`<库>_sync` 装载完成后原子 rename 成 `<库>`，旧库留一代 `<库>_prev`；报告落
`/opt/pg-ops/projects/<库名>-sync.md`（`ssh <host> sudo cat` 查看），含每表策略与行数、耗时、上一次
`sync_id`、回滚命令。

**步骤数 / 命令数 / TTHW 估算**（人工步骤，含填 env 与贴值；**均为估算**，实测数字待 example-app 首次真跑回填）：

| | 步骤数 | 命令数 | TTHW |
|---|---|---|---|
| 一次性准备（rsync 路线，两台机各跑一次） | 约 4 步 | 约 6 条 | 估算 15–20 分钟 |
| 一次性准备（OSS 路线，含控制台建 bucket/子账号） | 约 3 步 | 约 2 条（两次 `ossutil config`） | 估算 10–15 分钟（不含云控制台审批等待） |
| 单次同步（schema + data 都跑，rsync 路线） | 7 步（生产 5 + dev 2） | 约 7 条 | 估算：视库大小从数分钟到数十分钟不等 |

## 边界与安全，一眼看完

- 所有脚本幂等，重跑只会打印「已存在，跳过」；数据目录永远不碰。
- 装机 / 建库脚本都带生产守卫 `PG_OPS_ROLE=dev`，生产机的 env 里永远不要出现它；生产装机是另一个 skill（`pg-prod-server`，规划中）。
- `.pg-ops/` 含口令，`pgops-guard.sh` 会自动幂等把它加进 `.gitignore` / `.claudeignore` / `.claude/settings.json` 的
  deny（`Read(./.pg-ops/**)`，仅 Claude Code 宿主生效，Codex 无此机制）；`build/` 里的脚本用完可删。
  模型侧不打口令值到 stdout：取回都经 `pgops-fetch.sh` 落本地文件，不在回复里回显内容，人自己 `cat` 或登录服务器 `sudo cat`。
- 一个项目一个库一个 owner。最小权限拆分（app DML / migrate DDL / readonly）归 `pg-roles`（规划中）。
- 生产 → 开发的数据同步归 `pg-sync`（场景 D，首版已实现）；备份归 `pg-backup`（规划中）。pg-sync 的生产侧脚本模型
  永远不碰（ADR-0001），不要拿建库脚本灌数据。

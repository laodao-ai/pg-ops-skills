# pg-ops 规划：目标态与实施路线

> **本文是 pg-ops 运维线全部 skill 规划的唯一真相源。** 新增 / 改名 / 去重任何 skill，先改本文的
> §2 落位表。

---

## 0. 怎么读这份文档

### 0.1 分区

| 节 | 装什么 | 谁看 |
|---|---|---|
| §1 | **目标态**：为什么要这一套 | 第一次接触本仓的人 |
| §2 | **落位表**：4 个 skill 一张表，4 已实现 | 想知道「有没有这个 skill」 |
| §3 | **规划中的 6 个逐个**：做什么 / 依据 / 前置 / 成本 | 准备开下一个 change |
| §4 | **实施顺序与依赖** | 决定先做哪个 |
| §5 | **规格来源**：未来 skill 的输入规格（判别规则、参数三桶、建连成本） | 真正动手写那个 skill 时 |
| §6 | **待拍板 · 待人给 · 待核** | 卡住时看这里 |
| §7 | 落位约定 | 新增 skill 时 |

§5 是规格而非路线图——它体量最大，但只在实施某个具体 skill 时才需要读。找顺序看 §4，找清单看 §2。

---

## 1. 目标态

### 1.1 覆盖 PostgreSQL 运维全生命周期

目标态是**覆盖 PostgreSQL 服务本身运维的工具面**：装机 → 建库建角色 → 备份同步 → 调优监控 →
角色审计，服务任意 PostgreSQL 项目，本仓零项目知识。

### 1.2 三条设计原则（所有 skill MUST 遵守）

1. **每个操作是可复跑脚本 + 明确出口**：成功 / 失败 / 需要人做什么，三态清楚；agent 看不见终端，
   所以「需要人做什么」MUST 以**产物文件**形式交付（stdout 只给路径）。
2. **写权限边界清楚**：生产侧脚本只读 dump，MUST NOT 有任何写生产库的路径；恢复 / 灌库类脚本
   MUST 校验目标非生产。
3. **服务器是真相源**：口令在服务器首次生成、之后沿用；交接文档写到 `/opt/pg-ops/`。

**安全边界（高于任何单个 skill）**：MUST NOT 有任何 skill 持有生产库的写凭据。写类 skill 的执行动作
要么在 dev 库自动跑，要么产出文件交人在受控通道执行。

这三条已经在已实现的 3 个运维 skill 里兑现（幂等装机脚本、生产守卫 `PG_OPS_ROLE=dev`、交接文档产物式
出口），规划中的 6 个继承同一套；`pg-ops-upgrade` 属工具线，不涉这三条。

---

## 2. 落位表：4 个 skill

**状态**：✅ 已实现（`setup.sh` 已登记）· ⬜ 规划（`setup.sh` MUST NOT 登记）

| skill | 状态 | 一句话 | 依据 |
|---|---|---|---|
| `pg-dev-server` | ✅ | 开发 DB 服务器装机：PG18 + PgBouncer×2 + Redis，全回环 | T82 / T83 |
| `pg-dev-init` | ✅ | 给一个项目建库 + owner 角色 + scratch 库（只需库名） | T83 |
| `pg-sync` | ✅ | 生产 → 开发快照，schema / data 两阶段 | T83 |
| `pg-ops-upgrade` | ✅ | 运行 checkout 升级三连 | — |
| `pg-sizing` | ⬜ | 定规格与桶 2 参数 → `sizing.md` + 预填 env | 2026-09-05 |
| `pg-prod-server` | ⬜ | 生产装机，FRESH 新装 / ADOPT 接管两入口（**ADOPT 进首版且先做**，§6.1 #1） | 2026-09-05 |
| `pg-backup` | ⬜ | 备份 + 恢复 + 校验 + 演练（含原 `pg-restore`/`pg-health`） | T85 |
| `pg-roles` | ⬜ | 最小权限三角色 + 密码轮换 runbook + 审计参数 | T90 |
| `pg-monitor` | ⬜ | exporter + Alertmanager → 钉钉加签 Webhook | T88 |
| `pg-tune` | ⬜ | 上线后分析报告（含原 `pg-drift`/`pg-deploy-plan`） | 2026-09-05 |

**已去重的 4 个名字**（曾出现在旧规划里，不再单列）：

| 旧名 | 并入 | 理由 |
|---|---|---|
| `db-drift` | `pg-tune` | 同为「复用采集引擎产报告交人」心智 |
| `db-deploy-plan` | `pg-tune` | 同上（发布前检查 = 上线后分析的镜像） |
| `db-restore` | `pg-backup` | 备份与恢复是一件事的两半，分开会让恢复演练无家可归 |
| `db-health` | `pg-backup` + `shared/diag/` | 体检能力已在 `shared/diag/` 七个脚本里，且经真实事故验证 |

---

## 3. 规划中的 6 个

### 3.1 `pg-sizing`

- **做什么**：以 pgtune Web 档公式为底 + 本仓三条修正，产 `.pg-ops/sizing.md`（每维度：输入事实、
  套用规则、结论、备选与代价、下次重算信号）+ 预填 `pg-prod-server.env`。
- **两种输入模式**，公式与输出相同：

  | 输入项 | 问人模式 | 查库模式（只读） |
  |---|---|---|
  | 数据量、热数据 | 估，或保守档 | `pg_database_size`、`pg_stat_user_tables` heap 读 vs 缓存命中 |
  | 峰值连接、TPS | 估 | `pg_stat_database.xact_commit` 增量、`max(numbackends)`、PgBouncer `SHOW STATS` |
  | 内存、核、盘 | 目标规格 | `/proc/meminfo`、`nproc`、`df` |
  | WAL 产量 | 缺省 4 GB | `pg_stat_wal` 或 `pg_current_wal_lsn` 两次差值 |
  | **每秒新建连接数 R** | **必问**（见 §5.3 建连成本） | PgBouncer `SHOW STATS` / 日志 `connection authorized` 计数 |

- **算术交 `scripts/size.sh`**（六个数字进、参数表出），模型只问问题与解释取舍。脚本兜底确定性，
  模型只管判断——与本仓既有形态一致。
- **首次上线用「问人」模式起步，上线三个月后切「查库」模式重算一次。**
- **规格来源**：§5.3（判别规则）+ §5.4（参数三桶）+ §5.5（公式取法）。
- **验收**：dev 那台机器可先跑一遍查库模式当验收，顺带看 dev 参数该不该动。同批验收
  §5.4 标「dev 待补」的两项（THP、overcommit）。

### 3.2 `pg-prod-server`

- **做什么**：生产数据库服务器装机。自身几乎无可调参数，都从 env 读；桶 1 写死；B 层按 ROLE 反向；
  网络面按分机。守卫：`PG_OPS_ROLE` 不是 `prod` 拒跑。
- **两个入口**：

```
                       pg-prod-server
                             |
            +----------------+----------------+
            |                                 |
        FRESH 新装                        ADOPT 接管既有机
   新生产机、PG 18、env 全控          非 pg-ops 装的机器、别人的 ini
                                      只加不改：装 /opt/pg-ops/ + diag
                                      + needrestart list-only + apt hold
                                      + 按*观测态*渲染交接文档
                                      MUST NOT 重写任何现有配置
```

- **ADOPT 的必要性**：至今所有真实生产操作都发生在一台非 pg-ops 装的机器上（PG 16、别人的
  `pgbouncer.ini`、`listen_addr = 0.0.0.0`、`min_pool_size = 5`），而旧规划只有新装一条路，
  于是 `pgbouncer-second-instance.sh` 只能写成「从现有 ini 派生」的散装脚本。
- **共用**：A 层（apt 源、PgBouncer 双实例、Redis、conf.d 托管、探活、文档渲染）抽 `shared/`。
- **四条从真实事故来的硬要求**：见 §5.6。
- **前置**：**按分支不同**——FRESH 消费 `pg-sizing` 的产物；**ADOPT 无前置**（只加不改，没有参数要从
  sizing 取）。2026-09-09 拍板 ADOPT **进首版**（§6.1 #1），建议拆两个 change、ADOPT 先，见 §4.3 第 1 条。

### 3.3 `pg-backup`

- **做什么**：接 RPO 第二档 —— pgBackRest + WAL 连续归档 + 本地备份盘 + OSS 异地仓库 + **恢复演练**。
  含原 `pg-restore`（恢复）与 `pg-health` 里的备份校验部分。
- **RPO 第二档直接推导出**：`wal_level = replica`、`archive_mode = on`、`archive_command` 交
  pgBackRest、独立备份盘、OSS 异地仓库。
- **≥1 T 分区库**走 pgBackRest / PG 原生增量 + WAL 归档，不用逻辑备份。
- **前置**：顺序依赖 `pg-prod-server`（备份盘挂载与 archive 参数在装机时设）。
- **源需求**：T85。

### 3.4 `pg-roles`

- **做什么**：最小权限角色供给模式（app DML / migrate DDL / readonly 三角色）、PgBouncer
  `admin_users`/`stats_users` 模板、密码轮换 runbook、审计参数。
- **与 `pg-dev-init` 的边界**：后者建的是 owner 角色（一个项目一个库一个 owner），角色分层是本 skill。
- **源需求**：T90。

### 3.5 `pg-monitor`

- **做什么**：exporter + Alertmanager → 钉钉加签 Webhook，分级去重；脚本版过渡。
- **与 `shared/diag/` 的边界**：diag 是**人触发的一次性排查**，monitor 是**持续采集 + 主动告警**。
  diag 的七个脚本已经定义了「该盯哪些信号」（CPU 相位、建连速率、每连接事务数、后端私有内存），
  monitor 的告警项应直接对齐这些信号，不另起一套。
- **源需求**：T88。

### 3.6 `pg-tune`

- **做什么**：上线后出分析报告（桶 3）。**先按 `shared/diag/` 定位 CPU 归属**（system% / 建连速率 /
  每连接事务数），再看 `pg_stat_statements` / 膨胀 / 索引使用。含原 `pg-drift`（结构漂移 diff）与
  `pg-deploy-plan`（发布步骤单）职能。
- **建议动作落生产 MUST 走消费项目的迁移流程，本仓只出报告。**
- **成本比排位低得多**：它的输入 `shared/diag/` 七个脚本**已经存在，且在两次真实生产事故里用过并
  解决了问题**。本 skill 的实质是「把已验证的散装脚本包成 skill + 一份报告模板 + 桶 3 信号表
  （§5.4）」，不是从零做调优引擎。排位建议见 §4。

---

## 4. 实施顺序与依赖

### 4.1 推荐序列（2026-09-09 按拍板 #1 重算）

拍板「现网 PG 16 是本仓长期对象」（§6.1 #1）后，`pg-prod-server` 的 ADOPT 分支不消费
`pg-sizing` 的产物（它只加不改、不写任何配置），于是从链尾提到了前段。

```
 梯队   skill                          为什么排这里
 ----   ----------------------------   -----------------------------------------------
  一     1. pg-prod-server (ADOPT)     无 sizing 前置 · 现网那台立刻受益
         2. pg-tune                    消费 ADOPT 装上去的常驻 diag
 ----   ----------------------------   -----------------------------------------------
  二     3. pg-sizing                  复用 pg-tune 的采集层；产 FRESH 的 env
         4. pg-prod-server (FRESH)     消费 sizing
         5. pg-backup                  装机时设 archive 参数
         6. pg-roles / pg-monitor      可并行
```

- **梯队二整体等「真要新装一台生产机」这个信号**。在那之前它的产物没有消费者——`pg-sizing` 的输出
  唯一去处是 FRESH 的 env。`docs/runbook-pg-major-upgrade-16-to-18.md` 自己的结论是「有价值但不急，
  先做 case 文档的 #1～#5」，所以当前不触发。
- **「校准值会随时间贬值」这条理由由梯队一承接**：真正在采集校准值的是 `shared/diag/`，把它
  资产化的是 `pg-tune`，不是 `pg-sizing`。

### 4.2 依赖图（一条硬依赖 + 一条弱依赖）

```
  pg-sizing ------> pg-prod-server (FRESH) ------> pg-backup     * 仅 FRESH 分支成立

  pg-prod-server (ADOPT) ---> pg-tune             * 弱依赖：ADOPT 让 diag 常驻到
                                                    /opt/pg-ops/bin/diag/；不做也能手工 scp
```

其余全是建议顺序，不是技术依赖，允许按拉动重排。

**ADOPT 不在 `pg-sizing → pg-prod-server` 这条链上**：它「只加不改」、不重写任何现有配置（§3.2），
没有参数要从 sizing 取。把两个分支当一条链排，是错误的排法。

### 4.3 对旧顺序的两处修正

1. **`pg-prod-server` 的 ADOPT 分支排第一位**（拍板 #1 的直接后果）。
   建议**拆两个 change**：ADOPT 先（只加不改、风险面小、现网那台立刻受益，A 层抽 `shared/` 在这一次
   做掉），FRESH 后（再加 PG / PgBouncer / Redis 安装与配置托管）。捆一起等于让现在能用的东西等一个
   不急的东西。
   ⚠️ **MUST NOT 把三条升级封锁（黑名单 / apt hold / needrestart list-only，§5.1 B 层）当成要等这个
   skill**——它们是三行命令加一个 `conf.d/` 文件，人上去跑一遍即可止血。ADOPT 的价值是让它幂等、
   可复核、写进交接文档，不是「唯一途径」。**现网那台是否已落这三条，待核**（见 §6.3）。

2. **`pg-tune` 排第二位，且 MUST 排在 `pg-sizing` 之前**。依据是对 `shared/diag/` 的实测核对：
   `pg-sizing`「查库模式」（§5.3）要的输入，diag 七个脚本已经采了六成——

   | `pg-sizing` 查库模式要的 | `shared/diag/` 现状 |
   |---|---|
   | `pg_database_size` | ✅ `pg-mem.sh` |
   | `pg_stat_database.xact_commit` / `numbackends` | ✅ `pg-conn-audit.sh` |
   | PgBouncer `SHOW STATS` / `SHOW POOLS` | ✅ 7 处 / 6 处 |
   | `MemAvailable` / `nproc` / `smaps_rollup` | ✅ 3 / 3 / 4 处 |
   | `pg_stat_user_tables` 热数据比 | ❌ 缺 |
   | `pg_stat_wal` WAL 产量 | ❌ 缺 |
   | `df` 盘容量 | ❌ 缺 |

   先做 `pg-tune` = 把这套采集资产化，`pg-sizing` 只剩补三项；反过来先做 `pg-sizing`，是为一台可能
   不会新装的机器写一层采集，而 `pg-tune` 之后还要再写一遍。

---

## 5. 规格来源

> 本节是未来 skill 的**输入规格**，不是路线图。只在真正实施某个 skill 时读对应小节。

### 5.1 开发服务器 → 生产服务器：三层差异

```
+--------------------------------------------------------------------+
|  A. 直接复用（dev 已做，prod 原样要）                              |
|     回环/内网监听 + 仅 SSH 管理 | scram | PgBouncer auth_query 双实例|
|     conf.d 托管配置 + managed 标记 | 幂等重跑 | 配置没变不重启      |
|     sshd 加固 / ufw / fail2ban | 服务器为真相源 /opt/pg-ops         |
+--------------------------------------------------------------------+
|  B. 反向（dev 的便利在 prod 是漏洞）                               |
|     postgres 网络口令        --> prod 不设，只本地 peer 登录        |
|     交接文档含全部口令       --> prod 文档只写角色名，口令进 secret  |
|     unattended-upgrades 全开 --> prod 把 postgresql-* / pgbouncer / |
|                                  redis-server 列入 Package-Blacklist|
|     needrestart 交互/自动    --> prod 强制 list-only（只列不重启）  |
|     应用用库 owner 角色      --> prod 应用只拿 DML 角色（pg-roles）  |
|     scratch 库 / 可炸        --> prod 没有这个概念                  |
|     PG_OPS_ROLE=dev 守卫     --> 反过来：不是 prod 拒跑             |
+--------------------------------------------------------------------+
|  C. 新增（dev 根本没有的能力）                                     |
|     数据不能丢：WAL 归档 + 定时备份 + 异地 + 恢复演练（pg-backup）  |
|     看得见：exporter / 脚本巡检 + 钉钉告警（pg-monitor）            |
|     权限分层：app / migrate / readonly 三角色（pg-roles）           |
|     容量与调参：按机器规格推导（pg-sizing）                        |
|     Redis 持久化策略：会话可丢也要定 RDB 还是 AOF                  |
|     可用性目标：RTO / RPO 定数 -> 决定要不要 standby                |
+--------------------------------------------------------------------+
```

B 层三条要特别记住：

- **`postgres` 网络口令是纯开发机的决定**。生产上看全库走只读角色，管理走服务器本地
  `sudo -u postgres psql`；不能有「知道口令就是超管」的网络路径。装机脚本这一段 MUST 按 ROLE 分叉。
- **unattended-upgrades**：`postgresql-18` 包升级的 postinst 会直接重启集群 = 计划外停机。
- **needrestart 是独立于 unattended-upgrades 的第二条重启路径，黑名单挡不住它**。
  `postgresql-*` 进 Package-Blacklist 只保证「PG 包本身不被升级」；但 `libssl` / `libc` 这类共享库照升，
  升完 needrestart 发现 postgres / pgbouncer / redis 还在用旧 so 就会重启它们——PG 包一行没动，集群照样重启。
  2026-09-05 在现网 PG 16 上实测撞到，三个服务都被默认勾选，回车即重启生产库。
  处置：`echo '$nrconf{restart} = "l";' > /etc/needrestart/conf.d/pg-ops.conf`（写 `conf.d/` 而非改主配置，
  避免与发行版托管文件打架）。Ubuntu 24.04 的 "Ubuntu mode" 曾让这个开关失效，
  `needrestart 3.6-7ubuntu4.1` 起修复为「显式配了 restart 模式就关掉 Ubuntu mode」——
  **装完 MUST 验一次 `needrestart -v` 的版本与实际行为**，不能只写完配置就当数。

**分机带来的网络面**（dev 完全没有）：

- PG / PgBouncer / Redis 监听内网 IP（不再只回环）。
- `pg_hba.conf` 只放应用机内网 IP `/32` + scram；建议 `hostssl` + 自签证书（可记账后做）。
- 云安全组：只放应用机所在安全组为来源，端口只开 PgBouncer 两个口 + Redis；
  **5432 直连 MUST NOT 对应用机开放**（安全组与 `pg_hba` 两层都不放），迁移经 SSH 隧道或走 session 口。
  这是**结构性防线而不是建议**：真实事故里应用能绕过 PgBouncer 每秒建 463 个连接，前提就是 5432 可达；
  5432 不可达时「装了池却没走池」这一整类事故不可能发生。

### 5.2 RTO / RPO：已定第二档

```
     最后一次备份            事故            服务恢复
  ------+---------------------+---------------+----------> 时间
        |<------ RPO -------->|<---- RTO ---->|
        |  这段的写入丢了     |  这段用户在等 |
```

| 档 | RPO | RTO | 需要的东西 | 代价 |
|---|---|---|---|---|
| 一 | 24 h | 数小时 | 每晚 pg_dump + 异地副本 | 几乎为零 |
| **二（已定）** | 5 min | 1 h | 上面 + WAL 连续归档（PITR） | 一块备份盘 + pgBackRest，恢复由人操作 |
| 三 | 秒级 | 分钟 | 上面 + 流复制 standby | 第二台同规格机器 + 切换演练 |

选二的理由：数据不能随便丢一天，但可接受人上线恢复一小时。**升到三的信号**：第二个人出现，
或一次事故的客户可见成本不可承受。

### 5.3 资源判别规则（`pg-sizing` 的规则源）

每条都是「问一个事实 → 推一个结论」：

```
 输入（人给或查库）                     推导                        输出
 ---------------------------------      -------------------------   ---------------
 数据量 D、年增长 g、规划年限 y    -->  数据盘 = D x (1+g)^y x 2     容量 + 扩容信号
 热数据（常查的那部分）H           -->  内存 >= H x 1.5 才不落盘     机器内存档位
 峰值 TPS、并发连接数 C            -->  vCPU、pool_size、max_conn    规格 + 池参数
 RPO / RTO 档位                    -->  备份模式、备份盘、异地       pg-backup 的参数
 应用与 DB 同机 / 分机             -->  监听、pg_hba、TLS、安全组    网络面
 Redis 用途（会话/缓存/队列）      -->  持久化模式、maxmemory        Redis 参数
 每秒新建连接数 R                  -->  要不要池 / 池模式            见「建连成本」
```

| 维度 | 规则（起手版） | 备选与代价 |
|---|---|---|
| 内存档位 | 热数据 ≤ 2 GB 取 8 GB；≤ 6 GB 取 16 GB；再大按热数据 × 1.5 向上取整到 16 的倍数。不知道热数据用总量的 20% 估 | 少给内存不会坏，只是查询落盘变慢；先小后扩比反过来便宜 |
| PG 内存参数 | shared_buffers = 内存 1/4（上限 8 GB）；effective_cache_size = 3/4；work_mem = 内存/4 ÷ max_connections；maintenance_work_mem = 内存/16 | PG 社区通用起手值 |
| vCPU | 峰值 TPS < 500 取 2～4 核；每多 1000 TPS 加 2 核；有大报表并行查询另加 | 核多了没害处只多花钱 |
| 连接 | PgBouncer pool_size = 2～4 × vCPU；max_connections = 所有池上限之和 + 20 预留；应用并发 C 落 max_client_conn。**另 MUST 问「每秒新建多少连接」** | C 很大而 TPS 小 = 该用 transaction 池的信号 |
| 数据盘类型 | 需要 IOPS < 2000 用 ESSD PL0，否则 PL1；随机写为主选高一档 | PL1 贵约一倍，checkpoint 抖动小 |
| 备份盘 | 全备大小 × 本地保留份数 + 每日 WAL 量 × 7 天，× 1.5 | 第二档 RPO 才需要 |
| 分机网络 | 分机 ⇒ 内网 IP 监听 + pg_hba `/32` + 安全组按来源组；TLS 默认自签 | 不开 TLS 省一步；可记账后做 |
| Redis | 会话用途取 RDB；队列或不可丢数据取 AOF everysec；maxmemory = 键量 × 平均大小 × 2，同机不超内存 1/4 | AOF 多一倍磁盘写入 |
| max_wal_size | 每 15 分钟 WAL 产量的 2～3 倍；不知道起步 4 GB，盘够就放大 | 只影响 checkpoint 频率，不影响数据安全 |

#### 建连成本：一条独立的判别规则

**「装了 PgBouncer」不等于「应用走了 PgBouncer」。** 真实案例里 PgBouncer 一直健康运行、`SHOW POOLS`
一切正常，但几个服务的连接串写的是 5432 直连，**全机 64% 的 CPU 烧在 fork 后端上**；改一个端口号后
CPU 峰值 75~90% → ~15%。

`pg-sizing` MUST 把建连速率当成**独立输入**，而不是从并发连接数推：

```
 输入                                 推导                             输出
 ----------------------------------   ------------------------------   --------------
 每秒新建连接数 R（问人或实测）  -->  建连 CPU = R x 单次成本          要不要池/池模式
 目标库的表数量 T                -->  单次成本 ~ 5ms + T/1000 x 0.5ms  上面那个系数
```

**单次建连成本实测 10.2 ms**（8000+ 张表的库），三段构成，都是纯 CPU：

| 组成 | 量级 | 说明 |
|---|---|---|
| `fork()` + 后端初始化 | 1~2 ms | 与库无关 |
| **SCRAM-SHA-256 认证** | **3~5 ms** | PBKDF2 迭代 4096 轮；`auth_type` 选 scram 就有 |
| relcache / catcache 冷启动 | 与表数量正相关 | **表越多越贵**，教科书上的「几毫秒」是干净小库的数字 |

判据：

- **R × 单次成本 > 0.5 核 ⇒ MUST 上连接池，且 MUST 验收应用确实走了池。**
- 验收两条，都要过：
  1. `pg_stat_activity.client_addr` **全部是 PgBouncer 所在地址**；出现应用机 IP 就是有服务直连。
  2. **每连接事务数** = `Δpg_stat_database.xact_commit / Δsessions` **≥ 100**。小于 10 = 池等于没用。

**代价：上池是用内存换 CPU，`default_pool_size` MUST 按实际并发设。** 常驻后端会累积 relcache/catcache
且 PostgreSQL 不主动回收，**表越多涨得越猛**。实测：8000+ 张表的库，每个常驻后端约 100~130 MB 私有内存；
后端数 9 → 34 时内存 +3.5 GB；**上池 40 分钟后 `default_pool_size=100` 被一次并发高峰开满，
近百个后端 × 130 MB 撞上 16 GB 无 swap 的机器——page cache 被挤光、负载 200、SSH 失联、只能控制台重启。**

- **上池前 MUST 算一行乘法**：各池 `pool_size` 之和 × 单后端 relcache ≤ 可用内存的一半。
  表多的库 MUST 实测（`shared/diag/pg-mem.sh`），不套教科书的几 MB。`pg-sizing` 的输出 MUST 打印这行乘法及结论。
- `default_pool_size` MUST 按**实测峰期活跃后端数**给（该案实测 2.3 个，原配 100，过量 40 倍），
  MUST NOT 照 `max_client_conn` 拍。session 模式下应用空闲连接也占位，所以池大小下限是
  「所有走这个池的应用实例 `maxOpen` 之和」——**应用侧连接池上限与 PgBouncer 池大小 MUST 一起定**。
- **无 swap 的机器内存撞顶不是 OOM 杀进程，而是整机 D 态卡死**，比被杀更难处置。生产机 MUST 配
  少量 swap（2~4 GB）或至少 `vm.overcommit_memory=2`，让失败发生在一个进程上而不是整机。
- `server_lifetime`（默认 3600s）是私有内存的天然上限——到点回收重建即归零。
- 内存排查 MUST 用 `smaps_rollup` 的 `Private_*`，**MUST NOT 用 RSS**（每个后端都映射了
  `shared_buffers`，RSS 会重复计算几十遍）；余量看 `MemAvailable`，不看云监控百分比。

#### 起步规格示例（阿里云 ECS 口径，数据几十 GB、含持续增长的分区表）

| 项 | 推荐 | 依据 |
|---|---|---|
| 规格 | 4 vCPU / 8 GB | PG 不吃核；8 GB 让 shared_buffers 有 2 GB 又留足页缓存。另配 2~4 GB swap 作撞顶止损 |
| 系统盘 | 40 GB | 系统 + 日志 + /opt/pg-ops |
| 数据盘 | ESSD PL1，起步 100 GB，可在线扩 | PG 数据目录 + Redis；PL0 随机 IO 拖慢 checkpoint |
| 备份盘 | 普通云盘，2~3 倍数据盘 | 本地留最近一份全备 + 一周 WAL，恢复不用等下载 |
| 异地 | OSS 一个 bucket | 备份盘与数据盘同机，机器没了一起没 |

```
/            系统盘        系统、/var/log、/opt/pg-ops
/data        数据盘 ESSD   /data/postgresql/18/main   PG 数据
                           /data/redis                Redis RDB
/backup      备份盘        /backup/pgbackrest         全备 + 增量 + WAL 归档
                                   |
                                   +---> OSS 异地仓库（pgBackRest repo2）
```

WAL 与数据同盘在这个量级没问题（分盘是万级 TPS 的事）；**备份盘 MUST 独立**：不抢数据盘 IOPS，
数据盘满了备份还在。

### 5.4 参数三桶

```
 桶 1 固定值            桶 2 按规格推导           桶 3 看负载再调
 装机脚本写死           pg-sizing 算出来落 env    上线后按监控信号改
 (dev / prod 都一样)    (每台机不同)              (每个业务不同)
```

#### 桶 1：装机脚本直接写死

**PostgreSQL**（✅ = dev 装机已实现，可直接抽 `shared/` 给 prod 复用）：

| 参数 | 值 | 现状 | 为什么 |
|---|---|---|---|
| random_page_cost | 1.1 | ✅ | 默认 4 是机械盘假设；不改优化器会躲着索引走 |
| effective_io_concurrency | 200 | ✅ | SSD 能并发预读，默认 1 是机械盘假设 |
| shared_preload_libraries | pg_stat_statements | ✅ | 桶 3 的数据来源；改了要重启，必须装机时开 |
| track_io_timing | on | ✅ | 同上 |
| log_connections | PG 18 取 `authorization`（≤17 取 `on`） | ✅ | 直连风暴在日志里就是报警 |
| log_line_prefix | `'%m [%p] %u@%d app=%a from=%r '` | ✅ | `%r` 来源地址，直连来源一眼可见 |
| jit | off | ✅ | 短事务 OLTP 里 JIT 开销大于收益 |
| pg_stat_statements.max | env 项，默认 50000（PG 默认 5000）；表名带变量的库按表数上调 | ✅ | 5000 装不下就每几秒淘汰一次，top 榜退化成「最高频」而非「最耗时」，归因全错。实测某库 `dealloc = 131 万`（每 12 秒一次）。**postmaster 级参数，装机时设就不必单独停机** |
| wal_compression | on | ⬜ prod | WAL 少写三到五成，CPU 代价可忽略 |
| checkpoint_completion_target | 0.9 | ⬜ prod | 把刷盘摊到整个周期，避免 IO 尖刺 |
| checkpoint_timeout | 15 min | ⬜ prod | 默认 5 分钟太密，配合 max_wal_size 放大 |
| idle_in_transaction_session_timeout | 10 min | ⬜ prod | 忘了提交的事务一直持锁、挡 vacuum；生产必设 |
| log_checkpoints / log_lock_waits / log_temp_files | on / on / 0 | ⬜ prod | 三个最便宜的诊断信号 |
| log_autovacuum_min_duration | 1 s | ⬜ prod | 看得见 vacuum 在哪张表上耗时 |
| timezone / log_timezone | 两边一致 | ⬜ prod | 日志时间与数据时间对不上是排障常见坑 |

**操作系统**：

| 项 | 值 | 现状 | 为什么 |
|---|---|---|---|
| vm.swappiness | 10 | ✅ | 只兜底不常态换页 |
| needrestart | `conf.d/90-pg-ops.conf` 里 `$nrconf{restart} = 'l'` | ✅ dev 已实现（0b 段） | 共享库升级后它会自动重启 PG/PgBouncer/Redis，黑名单挡不住 |
| **透明大页 THP** | never | ⬜ **dev 待补** | PG 官方建议关；THP 碎片整理造成延迟抖动 |
| **vm.overcommit_memory** | 2（overcommit_ratio 按内存算） | ⬜ **dev 待补** | 不让 OOM killer 随机杀 postgres，宁可分配失败 |
| vm.dirty_background_ratio / dirty_ratio | 5 / 10 | ⬜ prod | 内核脏页别攒到一次刷 |
| 数据盘文件系统 | xfs 或 ext4，挂载 noatime | ⬜ prod | 少一次每次读都写的 atime |
| I/O 调度器 | none 或 mq-deadline | ⬜ prod | 云盘是虚拟设备，内核排队没意义 |
| ulimit nofile | 65536 | ⬜ prod | 连接多时 PgBouncer 先撞文件句柄上限 |
| 时间同步 | chrony | ⬜ prod | WAL、备份、日志时间线全靠它 |
| unattended-upgrades | 黑名单 postgresql-* / pgbouncer / redis-server | ⬜ prod | 见 §5.1 B 层 |
| apt-mark hold | `postgresql-<ver>` / `-client-` / `-common` | ⬜ prod | 与上一行不互斥：黑名单只管自动升级，hold 连人工 `apt upgrade` 也挡住 |

**三条升级封锁（黑名单 / hold / needrestart）全做，各挡一条路**：自动升级、人工升级、共享库升级后的连带重启。

**PgBouncer**（来自内存撞顶事故；旧规划只提 `default_pool_size`/`max_client_conn`，事故里起作用的是整套）：

| 参数 | 值 | 为什么 |
|---|---|---|
| default_pool_size | transaction 实例按**实测峰期活跃后端数**（桶 2）；session 实例按走它的应用 `maxOpen` 之和 | 两个实例的数本来就不同，MUST 分两个 env 项 |
| min_pool_size | 0（显式写） | 非 0 等于每个活跃过的池常驻 N 个后端各 130 MB；生产不靠预热 |
| reserve_pool_size | 5 | 池满等超时后临时多开，给爆发一个出口而不是无限开 |
| server_lifetime | 600 | 常驻后端的 relcache 只增不减，lifetime 是私有内存的天然上限 |
| server_idle_timeout | 600 | 爆发过后多出来的后端回收 |
| query_wait_timeout | 120 | 排队上限，超时报错给应用而不是无限挂 |
| **max_db_connections** | `(可用内存 ÷ 2) ÷ 单后端私有内存` | 全局封顶，与各池 `pool_size` 无关：不管谁把池配大，一个库的后端总数也越不过内存预算 |
| listen_addr | 内网 IP | 两个实例都对应用机开，5432 不开 |
| admin_users / stats_users | 见 `pg-roles` | 管理台连法 MUST 写进交接文档（含 unix socket 也要口令这一条） |

装机脚本 MUST 打印那行乘法「Σ各池 pool_size × 单后端私有内存 ≤ 可用内存 ÷ 2」及结论，**超了拒跑**。
首次上线没有实测值时按 `20 MB + 表数 ÷ 100 MB` 估。

#### 桶 2：`pg-sizing` 推导落 env

shared_buffers、effective_cache_size、work_mem、maintenance_work_mem、max_connections、max_wal_size、
PgBouncer 两个实例各自的 `default_pool_size` / `max_client_conn` / `max_db_connections`、
Redis `maxmemory` 与持久化模式。规则见 §5.3。

#### 桶 3：看到信号才动（`pg-tune` 的范围）

| 信号 | 动作 |
|---|---|
| `pg_stat_bgwriter` 里 checkpoints_req 远多于 checkpoints_timed | max_wal_size 放大 |
| temp_files 持续增长 | work_mem 加，或找那条查询 |
| 某表 n_dead_tup 高、autovacuum 追不上 | 按表调 autovacuum_vacuum_scale_factor（大表 0.2 → 0.01~0.05） |
| 缓存命中率 < 99% | 内存档位升一级，回桶 2 重算 |
| PgBouncer cl_waiting 持续 > 0 | pool_size 加，或看是不是慢查询占着连接 |
| 长事务告警频繁 | 先查应用，再考虑 statement_timeout |

autovacuum 说明：持续追加、按月切分的分区表死元组少，默认参数够；要盯的是高频更新的业务表
（会话、计数类）。全局调不如按表设，所以属桶 3。**桶 3 建议的动作若是按表改参数或加索引，
落生产 MUST 走消费项目的迁移流程，本仓只出报告。**

### 5.5 调参工具为什么互相冲突，我们怎么取

| 工具 | 是什么 | 隐含假设 |
|---|---|---|
| pgtune（le0pard） | 输入内存/核/盘类型/负载类型，输出参数 | 五种负载档不同公式；有盘类型 |
| PGConfigurator（CYBERTEC） | 同类 | 偏保守，更多内存留给页缓存 |
| pgconfig.org | 同类，带参数解释 | 公式接近 pgtune，缺省不同 |
| postgresqltuner.pl | 连正在跑的库读 pg_stat 给建议 | 桶 3 工具，需要真实负载 |
| PG 官方 wiki「Tuning Your PostgreSQL Server」 | 原则与范围，不给公式 | 一手来源 |

打架的五处及原因：

1. **work_mem**（差距最大，可差四倍）：它是**每个排序/哈希操作一份**而非每连接一份，各家对「一条查询
   几份」估计不同。前有 PgBouncer 时 max_connections 小可放宽；总量乘起来不超内存 1/4 即可。
2. **shared_buffers 25% vs 40%**：官方说 25% 是合理起点、>40% 通常无益；40% 是老文章。取 25%，上限 8 GB。
3. **effective_cache_size 50% vs 75%**：不分配内存，只告诉优化器页缓存大小。独占机器 75%，同机跑应用 50%。
   已定分机 ⇒ 75%。
4. **random_page_cost 1.1 vs 4**：4 是机械盘时代假设；SSD 取 1.1~1.5。给 4 的是过时，不是取舍。
5. **max_wal_size / checkpoint_timeout**：只影响 checkpoint 频率与崩溃恢复时长，盘越大越可放宽。

**规律：冲突都在合理区间内的位置，不在方向。** PG 对区间内取值不敏感，出问题的是数量级错误
（random_page_cost 留 4、work_mem 1 GB、shared_buffers 80%）。

**已定取法**：`pg-sizing` 只认一套公式 = **pgtune Web 档**（开源、简单、`size.sh` 可原样复现、
与网页可对照），叠加本仓已知前提的修正。候选修正三条（待最终确认，见 §6）：

| 修正 | 内容 | 依据 |
|---|---|---|
| PgBouncer 在前 | max_connections 按池上限之和 + 20，work_mem 相应放宽 | pgtune 不知道有池 |
| 分机独占 | effective_cache_size 取 75% | pgtune 不问是否同机 |
| 云 SSD | random_page_cost 1.1、effective_io_concurrency 200 | pgtune 的 SSD 选项已含，明确写入以防被改 |

每个参数在 `sizing.md` 里写「取值 + 合理区间 + 我们为什么取这一端」，**把冲突变成可见的选择**。

### 5.6 `pg-prod-server` 的四条硬要求（来自真实事故）

1. **端口语义 MUST NOT 写死数字。** 现网既有机是 6432 session / 7432 transaction，dev 正相反
   （历史决定）。systemd 单元名用 `pgbouncer-<mode>`，端口全从 env 来，交接文档按实际 ini 生成。
   抽 `shared/` 时以「从 env 取端口」的写法为准，不要沿用 dev 装机里端口与模式配对固定的手写单元。
2. **auth_query 用 dev 那个函数。** 既有机的 `pgbouncer_auth` 直读 `pg_shadow`，是超级用户级别；
   dev 的 `pgbouncer.get_auth`（SECURITY DEFINER、排除 `rolsuper`）更对，放 `shared/` 两边共用。
3. **装机后自检 MUST 含「用了池 vs 装了池」两条**（§5.3 的验收方法，从 SHOULD 升为 MUST）。
   自检脚本与 `shared/diag/` 一起装到 `/opt/pg-ops/bin/diag/`，交接文档「运维要点」引用；
   **重启 / reload / stop 类操作前 MUST 先跑一条快照命令留证据。**
4. **交接文档加「应用侧连接池契约」**（通用版，不带任何框架键名）：池上限必设、idle 与 open 相等、
   lifetime 带单位、连接串带 `application_name=<服务名>`（多实例带实例名）、lib/pq 类驱动走
   transaction 口 MUST 加 `binary_parameters=yes`（报 `unnamed prepared statement does not exist`
   先加它，不是换 session 口）、验收用第 3 条两条自检。
   **框架特定的键名归消费项目仓，本仓 MUST NOT 出现。**

---

## 6. 待拍板 · 待人给 · 待核

### 6.1 待拍板（只有人能定）

| # | 事项 | 阻塞什么 | 现状与倾向 |
|---|---|---|---|
| 1 | ~~现网 PG 16 库是不是本仓的长期对象~~ | ~~`pg-prod-server` 首版要不要含 ADOPT 入口~~ | ✅ **2026-09-09 已拍板：是**。认定为长期对象，**ADOPT 进首版**。依据：两次事故止血、PgBouncer 第二实例、变更单都发生在那台机器上，还欠着 `pg_stat_statements.max` 的重启窗口、多个服务切端口、16→18 升级。**后果已落 §4**——ADOPT 不消费 sizing 产物，排第一位，且建议与 FRESH 拆两个 change |
| 2 | §5.5 三条修正的最终清单 | `pg-sizing` 的公式定稿 | 三条都有依据，倾向全采纳 |
| 3 | Redis 生产用途只有会话吗 | 决定 RDB / AOF | — |
| 4 | TLS 是首版就开还是记账 | `pg-prod-server` 网络面 | 内网被嗅探概率低，倾向记账后做 |
| 5 | timezone 统一取 UTC 还是 Asia/Shanghai | 桶 1 参数 | 两边一致即可，取哪个都行 |

### 6.2 待人给（`pg-sizing` 问人模式的输入）

生产数据量 D、年增长 g、热数据估计 H、峰值连接 C、峰值 TPS、**每秒新建连接数 R**。

**已有校准值**（来自现网实测，可作为量级参照）：直连期峰期 **463 连接/秒**、单次建连成本 **10.2 ms**
（8000+ 张表）、单后端私有内存 **100~130 MB**、整改后每实例 4 条常驻、30 分钟一换、实测峰期活跃后端 **2.3**。

> 这些校准值会随时间贬值——机器、库、负载都在变。**采集它们的是 `shared/diag/`，把采集资产化的是
> `pg-tune`**（§4.3 第 2 条），所以「越早越值钱」指向的是 `pg-tune` 早做，不是 `pg-sizing` 早做。

### 6.3 待核（机器上一跑就知道，但需要人上生产机）

| # | 待核什么 | 为什么要核 |
|---|---|---|
| 1 | 现网 PG 16 那台是否已落**三条升级封锁**（unattended-upgrades 黑名单 / `apt-mark hold` / needrestart list-only） | §5.1 B 层：2026-09-05 实测撞到过「回车即重启生产库」。三行命令即可止血，**MUST NOT 等 `pg-prod-server` ADOPT**（§4.3 第 1 条） |
| 2 | needrestart 版本与实际行为（`needrestart -v`） | Ubuntu 24.04 的 "Ubuntu mode" 曾让 list-only 开关失效，`3.6-7ubuntu4.1` 起才修复；写完配置不等于生效（§5.1） |

---

## 7. 落位约定

1. **新增 / 改名 / 去重任何 skill，先改本文 §2 落位表**，再动代码。
2. `setup.sh` 的 `install_skill` 列表**只登记已实现的 skill**；规划中的 MUST NOT 登记。
3. skill 实现完成后：§2 状态改 ✅ → `setup.sh` 登记 → `README.md` 的 Skills 表加一行 →
   `docs/skills-guide.md` / `.html` 加使用说明。
4. 与 SAD（`openspec/architecture/sad.md`）的分工：SAD 管子系统边界与 contract（空间），本文管
   清单、顺序、卡点（时间）。本文改了之后，回头同步 SAD 里对应的成熟度标记。

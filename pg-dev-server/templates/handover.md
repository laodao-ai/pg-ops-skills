# 开发数据库服务器交接文档：{{SSH_TARGET}}

生成时间：{{GENERATED_AT}}，主机 {{HOSTNAME_FQDN}}。由 pg-ops/pg-dev-server 装机脚本写在服务器 `{{PG_OPS_DIR}}/handover.md`，重跑装机会更新。
取回（开发机执行）：`bash <skill-dir>/scripts/pgops-fetch.sh {{SSH_TARGET}} {{PG_OPS_DIR}}/handover.md`。**本文含口令，只经安全渠道传递，不要提交到任何仓库。**

## 0. 需要人操作 / 确认的事项

脚本做不了或不该替人决定的，都在这里。做完一项勾一项。

- [ ] **云安全组**：入方向只留 22，不给 5432 / {{PGB_PORT}} / {{PGB_SESSION_PORT}} / {{REDIS_PORT}} 开任何入站（要求与验证命令见第 4 节 ①）。
- [ ] **口令入库**：第 2 节的 postgres 与 Redis 口令、`{{PG_OPS_DIR}}/projects/` 下各项目库口令，收进各自的 secret 工具；本文不进任何仓库。
- [{{HARDEN_BOX}}] **主机加固**：{{HARDEN_TODO}}
- [ ] **SSH 来源白名单**：{{SSH_SCOPE_DOC}}
- [ ] **备份**：本机未配置任何备份。开发库里有不想丢的数据时自行 `pg_dump`（5432 直连口），或等 pg-backup。

## 1. 服务器

| 项 | 值 |
|---|---|
| SSH | `{{SSH_TARGET}}` |
| 公网 IP | {{PUBLIC_IP}} |
| 系统 | {{OS_PRETTY}} |
| PostgreSQL | {{PG_VERSION}}，直连口 127.0.0.1:5432，数据目录 `{{DATA_ROOT}}/postgresql/{{PG_MAJOR}}/main` |
| PgBouncer | {{PGB_VERSION}}，两个实例：127.0.0.1:{{PGB_PORT}} **transaction** 池 · 127.0.0.1:{{PGB_SESSION_PORT}} **session** 池（区别与选法见第 3 节），都是 auth_query 模式（新建的库角色自动可用，无需登记） |
| Redis | {{REDIS_VERSION}}，127.0.0.1:{{REDIS_PORT}}，数据目录 `{{DATA_ROOT}}/redis`，maxmemory {{REDIS_MAXMEMORY}}，allkeys-lru |
| swap | {{SWAP_GB}} G |

所有服务只监听回环地址，公网只开 SSH。任何客户端都经 SSH 隧道进来。

## 2. 凭据

| 项 | 值 | 说明 |
|---|---|---|
| PostgreSQL 超级用户 | 用户 `postgres`，口令 `{{PG_SUPER_PASS}}` | 看和管全部库，给人和 DB 工具用；只走 5432 直连口（两个 PgBouncer 口都拒绝超级用户）。项目应用一律用自己的库账号，不用它 |
| Redis 口令 | `{{REDIS_PASS}}` | 全服务器一个，各项目共用；项目间用不同 db 编号或 key 前缀隔离 |
| 项目库账号 | `sudo ls {{PG_OPS_DIR}}/projects/`，每库一份 `<库名>.md` | 每个项目一个库 + 一个 owner 角色，由 pg-dev-init 生成并记录 |

服务器上也可免口令本地登录：`sudo -u postgres psql`。换 postgres 口令：`sudo rm {{PG_OPS_DIR}}/postgres.pass` 后重跑装机（自动生成新口令），或开发机 env 填 `PG_SUPER_PASS` 重渲染执行。

## 3. 开发机接入（隧道）

```bash
ssh -N -L 5432:127.0.0.1:5432 -L {{PGB_PORT}}:127.0.0.1:{{PGB_PORT}} -L {{PGB_SESSION_PORT}}:127.0.0.1:{{PGB_SESSION_PORT}} -L {{REDIS_PORT}}:127.0.0.1:{{REDIS_PORT}} {{SSH_TARGET}}
```

写进 `~/.ssh/config` 更省事：

```
Host {{SSH_TARGET}}
    HostName {{PUBLIC_IP}}
    User <user>
    IdentityFile ~/.ssh/<key>
    LocalForward 5432 127.0.0.1:5432
    LocalForward {{PGB_PORT}} 127.0.0.1:{{PGB_PORT}}
    LocalForward {{PGB_SESSION_PORT}} 127.0.0.1:{{PGB_SESSION_PORT}}
    LocalForward {{REDIS_PORT}} 127.0.0.1:{{REDIS_PORT}}
    ServerAliveInterval 30
```

之后 `ssh -N {{SSH_TARGET}}` 起隧道。

### 三个 PostgreSQL 入口：两种 PgBouncer 模式 + 直连，怎么选

同一套库、同一套账号，三个端口只差「服务端连接怎么分配」。连接串只改端口，其余一样。

| 端口 | 模式 | 一个服务端连接归谁 | 用在 | 限制 |
|---|---|---|---|---|
| {{PGB_PORT}} | PgBouncer **transaction**（**lib/pq**，GoFrame/gogf `pgsql` 驱动即此） | 每个事务开始时借一个，事务结束立刻归还给别人用 | **仅为兼容既有代码保留，不是缺省**——已经跑在这个口上、且确认不依赖任何会话级特性的服务可以继续用；并发多的短事务在这里连接复用率最高 | 事务之间不保证还是同一个服务端连接，所以**会话级状态不可靠**：`SET` 会话变量、`SET ROLE`、会话级 advisory lock、`LISTEN`（订阅收不到；`NOTIFY` 发送不受影响）、逻辑复制 / CDC 连接、SQL 级 `PREPARE ... / EXECUTE` 跨事务、跨事务的临时表、`WITH HOLD` 游标。驱动走协议级的 prepared statement（pgx / JDBC / npgsql / psycopg3 / asyncpg 默认方式）**可以用**：PgBouncer 按客户端跟踪并在换到的连接上重新 prepare，每连接上限 max_prepared_statements=200。**lib/pq（含 GoFrame `pgsql` 驱动）DSN MUST 加 `binary_parameters=yes`** 才能走这个口——lib/pq 默认对带参数查询走两次往返（先 Parse/Describe 建无名预备语句、再 Bind/Execute），中间那次 `ReadyForQuery` 会被 PgBouncer 当成事务结束换后端，导致 `unnamed prepared statement does not exist`；`binary_parameters=yes` 让 Parse/Bind/Describe/Execute/Sync 一次发出，不留事务边界 |
| {{PGB_SESSION_PORT}} | PgBouncer **session** | 客户端连上就独占一个，断开才归还 | **经池子的缺省选择**——功能与直连一致，上面那些会话级特性全可用，不必逐个排查驱动行为。新服务、工具与脚本、ORM 迁移器、靠 advisory lock 的任务队列 / 定时任务、`LISTEN` 订阅进程、逻辑复制 / CDC 客户端、SQL 级 `PREPARE` 的校验类工具一律走它 | 功能无限制，和直连一样；但空闲客户端也占着服务端连接，同时连着的客户端超过 default_pool_size（{{PGB_DEFAULT_POOL_SIZE}}）就排队等。常驻的订阅 / 复制进程多了不如直连 5432 |
| 5432 | 直连 PostgreSQL | 无池，一客户端一连接 | 迁移工具、`pg_dump` / `pg_restore`、DB 工具浏览与管理、超级用户 `postgres` | 无功能限制；连接数受 PG `max_connections` |

判断顺序（**缺省 session**）：经池子就用 {{PGB_SESSION_PORT}}——功能无坑，不需要逐个排查驱动的预备语句行为。管理、备份、批量导入和 DB 工具直接 5432。
{{PGB_PORT}}（transaction）**只在两种情况下出现**：① 既有服务已经跑在这个口上、且确认不依赖任何会话级特性，保持不动；② 同时连着的客户端数会超过 `default_pool_size`（{{PGB_DEFAULT_POOL_SIZE}}）、必须靠事务级复用把后端连接数压下来——这时才值得付「会话级状态不可靠」的代价，并逐条核对上表 transaction 行列出的限制（尤其 lib/pq 的 `binary_parameters=yes`）。

> ⚠️ **换缺省带来的容量账要重算**：session 池下**空闲客户端也占着后端连接**，所以并发客户端数直接受
> `default_pool_size`（{{PGB_DEFAULT_POOL_SIZE}}）封顶，不像 transaction 池那样靠事务级复用摊薄。
> 下面「应用侧连接池契约」的 Σ 约束按端口分别算：走 {{PGB_SESSION_PORT}} 的各服务 `maxOpen` 之和
> MUST 不超过 {{PGB_DEFAULT_POOL_SIZE}}（+ reserve），**这个上限比 transaction 池更容易撞到**。
> 常驻的订阅 / 复制进程多了不如直连 5432。
两个 PgBouncer 口都拒绝超级用户 `postgres`（auth_query 排除了 rolsuper），它只能走 5432。

DB 工具（DBeaver / DataGrip / psql 等）看全部库：隧道起好后连 `127.0.0.1:5432`，用户 `postgres`，口令见第 2 节；库填 `postgres` 即可切换浏览所有库。

### 应用侧连接池契约（MUST / SHOULD，2026-09-06 pg16 两起连接风暴事故换来的）

任何服务连本机 PG（无论走 transaction 池、session 池还是直连）都要遵守：

- **池上限 MUST 设**：连接池的 `maxOpen`（`database/sql` 语义下等价字段：`MaxOpenConns` / GoFrame 的 `maxOpen` / `maxOpenConnCount`）MUST 显式设一个有限值，不能留默认的「无限制」。**Σ 维度**：同一 PgBouncer 端口/同一 PG 实例上会有多个服务同时连，各服务 `maxOpen` **之和** MUST 不超过该端口的 `default_pool_size + reserve_pool_size`（transaction 池 {{PGB_PORT}} 当前为 {{PGB_DEFAULT_POOL_SIZE}}；session 池 {{PGB_SESSION_PORT}} 与直连 5432 则受 PG `max_connections` 约束）——单个服务自己不超限不够，Σ 超了照样打满后端。
- **`maxIdle` = `maxOpen` MUST**：空闲上限与打开上限设成相等值，连接用完即回池、不主动关闭重连抖动；不要留 `maxIdle` 小于 `maxOpen` 的默认组合。
- **生命周期参数 MUST 带单位**：`maxConnLifetime` / `MaxConnLifeTime` 等生命周期字段 MUST 写带单位的字符串（如 `"30m"`），不能写裸数字——裸数字在部分框架（如 GoFrame `gconv.Duration` 对数值走 `time.Duration(int64)`）会被当成**纳秒**解析，连接建好即过期，池形同虚设。
- **`application_name` 服务名 MUST / 实例名 SHOULD**：DSN MUST 带 `application_name=<服务名>`，用于 `pg_stat_activity` / `pgb-console.sh` 按服务归因连接与事务量；多实例部署时把实例号也带上（如 `<服务名>-<实例号>`）是 SHOULD，不强制（2026-09-06 生产已拍板：默认不按实例改名）。
- **lib/pq（含 GoFrame `pgsql` 驱动）MUST 加 `binary_parameters=yes`**：见上表；不加会在 transaction 池上报 `unnamed prepared statement does not exist`。
- **验收方法与门槛**：装机 / 项目接入后跑 `sudo bash {{PG_OPS_DIR}}/bin/diag/pg-conn-audit.sh`（见第 5 节），看两项：① 该服务在 `ss` 归因里没有走「直连绕过隧道」之类的裸 sshd/未归因连接；② 采样窗口内每服务端连接的事务数（`Δxact / Δsessions`）**≥ 10**——低于这个数说明池没起作用（连接刚建好就被回收重建，参照上面「生命周期参数」条的病根）。（**10 是 dev 接入门槛；生产验收基准 ≥ 100；适用于应用运行时常规短事务，批处理 / 定时任务按自身负载形态另议。**）

## 4. 安全配置

原则：**对公网只暴露 SSH，其余一切只监听 127.0.0.1。** 四层各自独立成立：

| 层 | 在哪配 | 状态 |
|---|---|---|
| ① 云安全组 | 云控制台 | 人工项，要求见下，配好后按「验证」核一次 |
| ② 主机防火墙 ufw | 服务器 | {{UFW_STATUS}} |
| ③ 服务回环监听 | 装机脚本 | 已完成 |
| ④ sshd 加固 | 服务器 | {{SSHD_STATUS}} |

### ① 云安全组要求（以阿里云为例，控制台操作）

安全组是白名单，没写的规则一律拒绝。目标：**入方向只有 22 一条**。

1. 控制台 → 云服务器 ECS → 网络与安全 → 安全组 → 创建（普通安全组，VPC 与实例一致）。
2. 模板若自带 80 / 443 / 3389 放行，进去删掉，只留 22。
3. 实例 → 安全组 → 加入本组，并把其它已关联的安全组全部移出（最终规则是所有已关联安全组的并集）。

| 策略 | 协议 | 端口 | 授权对象 |
|---|---|---|---|
| 允许 | TCP | 22 | `<你的出口 IP>/32`（无固定 IP 才用 `0.0.0.0/0`，此时主机侧 fail2ban 必须在） |

不要为 5432 / {{PGB_PORT}} / {{PGB_SESSION_PORT}} / {{REDIS_PORT}} 添加任何入站规则。出方向保持默认允许（apt 与镜像需要出站）。

验证（在开发机上跑；22 通，其余应超时而不是拒绝）：

```bash
nc -zv -w3 {{PUBLIC_IP}} 22
for p in 5432 {{PGB_PORT}} {{PGB_SESSION_PORT}} {{REDIS_PORT}}; do nc -zv -w3 {{PUBLIC_IP}} $p; done
```

<!-- harden:start -->
### ②③④ 主机侧加固状态

**未执行。** 跑 `sudo bash {{PG_OPS_DIR}}/bin/pg-dev-server-harden.sh` 后本块会替换为实际生效的状态
（sshd 只密钥 / root 禁登、ufw 只放 22、fail2ban、自动安全更新）。
<!-- harden:end -->

### 复核命令（任何时候）

```bash
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin|maxauthtries) '
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo ss -tlnp | grep -E ':(5432|{{PGB_PORT}}|{{PGB_SESSION_PORT}}|{{REDIS_PORT}}) '     # 本地地址必须全是 127.0.0.1 / [::1]
systemctl is-enabled unattended-upgrades
```

## 5. 运维要点

- **查本文 / 查项目库**：`sudo cat {{PG_OPS_DIR}}/handover.md`，`sudo ls {{PG_OPS_DIR}}/projects/`。
- **原地重跑装机**：`sudo bash {{PG_OPS_DIR}}/bin/pg-dev-server-install.sh`（参数已内联，幂等，数据不动，PG 配置未变不重启，本文随之更新）。
- **只刷新本文**（不装包、不改配置、不重启）：`sudo env PG_OPS_DOCS_ONLY=1 bash {{PG_OPS_DIR}}/bin/pg-dev-server-install.sh`。
- **调参**：在开发机的项目仓改 `.pg-ops/pg-dev-server.env` → `render.sh` 渲染 → 上传执行，新脚本会覆盖 bin/ 里的旧版。
- **打补丁不会自动重数据库**：装机已把 needrestart 设为 list only（`/etc/needrestart/conf.d/90-pg-ops.conf`，
  pg-ops 托管，手改会被下次装机重写）。`apt` 升级共享库（libssl / libc）后只会**打印**哪些服务需要重启，
  不会自动重、也不弹默认勾选 PostgreSQL 的交互框。想让新库生效时自己挑窗口：
  `sudo needrestart -b | grep NEEDRESTART-SVC` 看清单，再 `sudo systemctl restart <服务>`。
- **目录说明**：`sudo cat {{PG_OPS_DIR}}/README.md`。
- **连接池体检**：`sudo bash {{PG_OPS_DIR}}/bin/diag/pg-conn-audit.sh`——按进程/服务归因当前连接走池还是直连，并采样每服务端连接的事务数，验收门槛见第 3 节「应用侧连接池契约」。
- **PgBouncer 管理控制台**：`sudo bash {{PG_OPS_DIR}}/bin/diag/pgb-console.sh`（无参数看两实例 `SHOW POOLS`，可传 SQL 在管理库上执行）。
- **其余诊断脚本**：见 `sudo cat {{PG_OPS_DIR}}/bin/diag/README.md`。
- **给新项目建库**：用 pg-dev-init，只需库名；账号口令写在 `{{PG_OPS_DIR}}/projects/<库名>.md`。
- **日志**：PG `/var/log/postgresql/postgresql-{{PG_MAJOR}}-main.log`，PgBouncer `/var/log/postgresql/pgbouncer.log`（transaction）与 `pgbouncer-session.log`（session），Redis `journalctl -u redis-server`。
- **PgBouncer 服务**：`pgbouncer`（transaction，{{PGB_PORT}}）与 `pgbouncer-session`（session，{{PGB_SESSION_PORT}}）两个 systemd 单元，`systemctl status pgbouncer pgbouncer-session`。
- **配置文件归属**：`/etc/postgresql/{{PG_MAJOR}}/main/conf.d/90-pg-ops.conf`、`/etc/pgbouncer/pgbouncer.ini`、`pgbouncer-session.ini`、`userlist.txt`、`/etc/systemd/system/pgbouncer-session.service` 由装机脚本整份重写（顶部有 managed 标记），手改会被下次装机覆盖。
- **备份**：本机未配置。生产级备份见 pg-backup；开发库需要时 `pg_dump` 经 5432 直连口即可。

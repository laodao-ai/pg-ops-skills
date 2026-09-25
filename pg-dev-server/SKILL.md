---
name: pg-dev-server
description: 引导填参并生成一台 Ubuntu 开发数据库服务器的自包含装机脚本（PostgreSQL 18 + PgBouncer 两实例（transaction / session 两种池模式按端口分开，auth_query）+ Redis，全部回环监听、仅 SSH 对外，幂等可重跑），默认由人上服务器执行，也可委托本 skill 经 ssh 代跑；只装服务器基础环境，不含任何项目的库 / 角色（那些用 pg-dev-init）。用于「搭开发数据库服务器」「dev DB server」「装 PG/PgBouncer/Redis」。
---

# pg-dev-server —— 开发数据库服务器装机（引导 → 生成脚本 → 执行 → 验证）

## 何时用

- 新开一台**开发**数据库服务器（与生产库物理分离）。一台服务器服务多个项目：本 skill 只装一次基础环境，
  之后每个项目各自用 `pg-dev-init` 建库，互不影响。
- 已装过的机器要调资源参数（swap / shared_buffers / Redis maxmemory 与淘汰策略）或升级本 skill 的配置：重新生成脚本再跑一遍，幂等。

**不做的事**：不建任何项目的库 / 角色（`pg-dev-init`）；不用于生产（生产的角色 / 备份 / 监控分别是
`pg-roles` / `pg-backup` / `pg-monitor`）；不配云安全组（控制台人工项，要求写在交接文档里）。

## 流程

### ⓪ 起手判断：这台服务器装过没有

只问一件事：目标主机的 ssh 别名。然后自己查，别问人「装过没」：

```bash
ssh <host> sudo test -f /opt/pg-ops/handover.md && echo INSTALLED || echo FRESH
```

- **FRESH** → 走 ①②③④⑤ 从零装机。
- **INSTALLED（新项目接入已有服务器，最常见）** → 不重装。做三件事就结束：
  1. `bash <skill-dir>/scripts/pgops-guard.sh .` 幂等确保 `.gitignore` / `.claudeignore` / `.claude/settings.json`
     都挡住了 `.pg-ops/`；再用 `pgops-env.sh set` 写 `.pg-ops/pg-dev-server.env`，至少填 `SSH_TARGET` 与 `PUBLIC_IP`
     （委托模式下 `ssh <host> curl -s ifconfig.me` 查，失败留空），其余留默认——这份 env 是 pg-dev-init 找服务器的依据：

     ```bash
     bash <skill-dir>/scripts/pgops-env.sh set .pg-ops/pg-dev-server.env --from <skill-dir>/pg-dev-server.env.example \
       SSH_TARGET=<别名> [PUBLIC_IP=<IP>]
     ```

  2. 取回交接文档副本（用 `pgops-fetch.sh`，MUST NOT 用 `ssh ... sudo cat` 把内容打进模型输出）：

     ```bash
     bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/handover.md
     ```

  3. 按 ④ 的收尾格式报两处路径，并提示下一步 `pg-dev-init`。**被 `pg-dev-init` 调用时**，做完 1、2 直接返回让它继续，不提示。
  人明确要求调参 / 重跑加固时才进 ②③⑤；只是文档模板升级了、或想刷新文档里的状态 → 走 ⑥ 只写文档模式，不重跑装机。

### ① 引导收参（只问人才知道的，其余取默认）

问清这几项，别问能自己查的：

| 问 | 为什么只有人知道 | 落到哪 |
|---|---|---|
| 目标主机的 ssh 别名 / `user@host` | 用来拼命令与命名产物 | 命令模板、输出文件名 |
| 机器规格（核数 / 内存） | 决定三项资源上限 | `SWAP_GB` / `PG_SHARED_BUFFERS` / `REDIS_MAXMEMORY`，缺省按 2 核 2G |
| 生产 PG 大版本 | 开发库 MUST 与生产一致 | `PG_MAJOR`，缺省 18 |
| 项目会不会在 Redis 里放无 TTL 的持久键（吊销 / 锁 / 计数） | 决定打满时淘汰谁；引擎不知道项目怎么用 Redis | `REDIS_MAXMEMORY_POLICY`，缺省 `volatile-lru`（只淘汰带 TTL 的键，纯缓存项目效果与 `allkeys-lru` 相同）；确认全是缓存可填 `allkeys-lru` |
| 数据放哪块盘 | 有没有独立数据盘只有人知道用途；委托模式下可先 `ssh <host> df -h` 看挂载点再提议 | `DATA_ROOT`，缺省 `/data`；没有数据盘就留空用 `/var/lib` |
| SSH 来源白名单 | 有没有固定出口 IP、办公网段是什么，只有人知道 | `SSH_ALLOW_FROM`（CIDR 空格分隔）；没有固定 IP 就留空，加固脚本改靠密钥 + fail2ban |
| 机器在不在国内 | 决定要不要 PGDG 镜像；能从 `/etc/apt/sources.list.d/ubuntu.sources` 的镜像地址推出来就直接提议 | `PGDG_MIRROR`，国内填 aliyun 镜像，否则留空 |
| 目标主机的公网 IP | 只用于交接文档里的安全组说明 | `PUBLIC_IP`；委托模式下可 `ssh <host> curl -s ifconfig.me` 查 |

其余（端口、池大小、`REDIS_PASS`、`PGB_AUTH_PASS`、`PG_SUPER_PASS`）一律默认留空：口令由服务器首次生成、之后沿用，记录在服务器的交接文档里，
开发机不保存口令。`SSH_TARGET` 填 ssh 别名。

### ② 生成脚本

**生成前 MUST 先做**：在项目根（git 仓根）执行 `pgops-guard.sh`，幂等确保 `.gitignore` / `.claudeignore` /
`.claude/settings.json` 三处都挡住了 `.pg-ops/`（含口令，不能进仓、不能进模型上下文）：

```bash
bash <skill-dir>/scripts/pgops-guard.sh .
```

env 与文档副本放**项目仓根目录的 `.pg-ops/`**（每个项目各自记自己的 dev server，不同项目不同服务器不冲突）。
用 `pgops-env.sh set` 按 ① 的答案落参数（MUST NOT 用 Edit / cat / sed 直接改这个文件；已有这个文件就只追加改动的键，
不要重新生成口令）：

```bash
bash <skill-dir>/scripts/pgops-env.sh set .pg-ops/pg-dev-server.env --from <skill-dir>/pg-dev-server.env.example \
  SSH_TARGET=<别名> [PUBLIC_IP=<IP>] [其余按 ① 的答案]
bash <skill-dir>/scripts/render.sh .pg-ops/pg-dev-server.env .pg-ops/build/install-<host>.sh
```

产物是**一份自包含脚本**（参数已内联，权限 700，可能含口令），放 `.pg-ops/build/`，用完可删。给人看一眼参数段（打星显示口令）再进 ③：

```bash
bash <skill-dir>/scripts/pgops-env.sh show .pg-ops/build/install-<host>.sh
```

### ③ 执行（默认人跑；人说「你来跑」再委托）

**人跑**：把这两行打印给人。脚本执行时会把自己装到服务器 `/opt/pg-ops/bin/pg-dev-server-install.sh`（可原地重跑），
所以第二行跑完删掉 `/tmp` 里的副本即可：

```bash
scp .pg-ops/build/install-<host>.sh <host>:/tmp/
ssh -t <host> 'sudo bash /tmp/install-<host>.sh; rm -f /tmp/install-<host>.sh'
```

**委托**：人明确说让 skill 执行时，用 Bash 依次跑上面两行，把输出原样带回来看。任何一行非零退出就停，
贴出错误，不要重试也不要改脚本绕过。
若消费仓已用 `pgops-guard.sh` 落了 `settings.json` 的 `Read(./.pg-ops/**)` deny，`scp .pg-ops/build/...` 这条命令的源参数
**可能**被一并拦下（Claude Code 官方文档未明确覆盖范围）——被拦即降级为「只打印给人跑」，MUST NOT 另造第四个工具绕过 deny。

脚本自身做的事（供解释输出）：守卫（`PG_OPS_ROLE=dev`、Ubuntu、root）→ 自装到 `/opt/pg-ops/bin` + 写 `README.md` → 解内嵌诊断脚本包到 `/opt/pg-ops/bin/diag/`（渲染版；直接版回退拷贝仓内 `pg-ops-shared/diag/`）→ swap → PGDG 源（发行版自带对应大版本则跳过）
→ 数据盘（先告诉 postgresql-common 新集群放 `DATA_ROOT`，再装包；已有集群在别处只警告不迁移）→ 装三个包 → PG 回环 + scram + `shared_buffers` + 审计日志（conf.d；配置有变才 restart，重跑不打断连接）
→ 超级用户 `postgres` 网络口令（首次生成存 `/opt/pg-ops/postgres.pass`、之后沿用；DB 工具经隧道连 5432 看 / 管全部库用，PgBouncer 拒绝超级用户）→ PgBouncer 认证角色 + `auth_query`
函数 → PgBouncer 两实例（transaction 池 `PGB_PORT`、session 池 `PGB_SESSION_PORT`，第二实例是脚本写的 systemd 单元 `pgbouncer-session`）→ Redis 回环 + requirepass + maxmemory + 淘汰策略（`REDIS_MAXMEMORY_POLICY`，值域校验早失败）→ 探活（任一失败即退出，含 postgres 网络口令登录）→ 写服务器交接文档 `/opt/pg-ops/handover.md` → 打印隧道命令。

### ④ 验证与交接

- 脚本末尾探活全过、并打印「交接文档已写入」才算完成；探活失败脚本会非零退出，不会假绿。
- **交接文档在服务器上**，取回给项目管理者（含 Redis 口令，走安全渠道；用 `pgops-fetch.sh`，MUST NOT 用
  `ssh ... sudo cat` 把内容打进模型输出）：

  内容：服务器信息与版本、postgres 与 Redis 口令、隧道命令与 ssh config（含 DB 工具用 postgres 连 5432 的说明）、四层安全配置
  （云安全组只放 22 / ufw / 回环 / sshd 加固）的操作步骤与检查清单、运维要点。安全组与 ufw / sshd 是人工项，本 skill 不动防火墙与 sshd，提醒人照文档过一遍。
- 提醒下一步：每个项目跑 `pg-dev-init`（只需库名），账号会记录在服务器 `/opt/pg-ops/projects/<库名>.md`。
- 项目仓 `.pg-ops/pg-dev-server.env` 留着（参数），下次调参重渲染用；同一台服务器被多个项目共用时，各项目各存一份，互不影响。

**收尾提示（MUST，装机与加固都适用）**：取回一份本地副本给项目管理者，最终回复里明确写出两处路径（内容本身 MUST NOT 出现在回复里）：

```bash
bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/handover.md
```

回复格式（照此说，别省略）：
> 交接文档已生成（含 postgres 与 Redis 口令，走安全渠道交给项目管理者）：
> - 服务器：`/opt/pg-ops/handover.md`，人也可登录服务器亲自 `sudo cat` 该路径
> - 项目仓副本：`.pg-ops/handover.md`（已 gitignore）
> 还需人工：云安全组入方向只留 22（文档第 4 节 ①）。

### ⑤ 主机安全加固（装机之后，同一份 env，另一份脚本）

```bash
bash <skill-dir>/scripts/render.sh .pg-ops/pg-dev-server.env .pg-ops/build/harden-<host>.sh harden
scp .pg-ops/build/harden-<host>.sh <host>:/tmp/
ssh -t <host> 'sudo bash /tmp/harden-<host>.sh; rm -f /tmp/harden-<host>.sh'
```

做的事：锁外防线（执行者没有公钥就拒跑）→ sshd 只密钥 / root 禁登 / 限次 → ufw 默认拒入只放 22（来源按
`SSH_ALLOW_FROM`，用 reset 重建所以改白名单也幂等）→ fail2ban sshd jail（systemd 后端）→ 自动安全更新 → 回写交接文档 ②④ 状态。
自装到 `/opt/pg-ops/bin/pg-dev-server-harden.sh`，可原地重跑。

**跑完必须另开一个 ssh 会话确认能登录**（委托模式下用 `ssh -o BatchMode=yes <host> true` 验证），当前会话别关；
登不上就在原会话 `sudo rm /etc/ssh/sshd_config.d/10-pg-ops.conf && sudo systemctl reload ssh` 回滚。
云安全组仍是人工项：提醒人照交接文档第 4 节 ① 在控制台配置，入方向只留 22。

### ⑥ 只重生成交接文档（`PG_OPS_DOCS_ONLY=1`，不装包、不改配置、不重启）

何时用：文档模板改了想让服务器上的交接文档跟上、或想刷新文档里的状态行；不想碰任何服务。口令一律沿用服务器现有的
（`redis.conf`、`/opt/pg-ops/postgres.pass`），本模式不生成口令：还没设过的会在文档里标「未设：跑一次完整装机」。
诊断脚本 `bin/diag/` 同样会随本模式刷新（不装包不改配置不重启，只解包 / 拷贝）。

```bash
# 模板没变，只刷新：原地跑 bin/ 里的脚本即可，不用重新渲染上传
ssh -t <host> 'sudo env PG_OPS_DOCS_ONLY=1 bash /opt/pg-ops/bin/pg-dev-server-install.sh'
# 模板变了：重新渲染上传（脚本会顺手把 bin/ 里的旧版换成新版），再以 DOCS_ONLY 执行
bash <skill-dir>/scripts/render.sh .pg-ops/pg-dev-server.env .pg-ops/build/install-<host>.sh
scp .pg-ops/build/install-<host>.sh <host>:/tmp/
ssh -t <host> 'sudo env PG_OPS_DOCS_ONLY=1 bash /tmp/install-<host>.sh; rm -f /tmp/install-<host>.sh'
```

跑完照 ④ 的收尾格式取回副本。没装过的机器上本模式会拒跑（没有 `/opt/pg-ops/handover.md`）。

## 查询（已装好的服务器，新项目 / 新同事要信息时）

```bash
bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/handover.md   # 服务器信息 / Redis 口令 / 隧道 / 安全配置
ssh <host> sudo ls /opt/pg-ops/projects/                                                     # 已有哪些项目库（不含口令，可直接打进回复）
bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/README.md # 目录与脚本使用说明
```

模型只取回到本地文件，不把内容打进回复；人自己 `cat`，或直接在服务器上 `sudo cat`。不用重跑装机，不用重新生成什么；真相在服务器上。

## 幂等与安全边界

- 三份配置文件由本 skill owns、整份重写（顶部有 managed 标记）；数据目录永远不碰；`redis.conf` 只改具体行。PG 配置内容没变就不 restart。
- 服务器 `/opt/pg-ops/` root 700：脚本、README、交接文档、`postgres.pass` 都在里面，含口令，不得复制进任何仓库。
- 超级用户 `postgres` 有网络口令但只能走 5432 直连；PgBouncer 的 auth_query 函数排除超级用户，两个池口都拒绝它。项目应用一律用自己的库账号。
- `PG_OPS_ROLE` 不是 `dev` 脚本拒跑；非 Ubuntu 拒跑。生产机的 env 里永远不要出现 `PG_OPS_ROLE=dev`。
- 含口令的 SQL 会话级关闭 `log_statement`，不会以 DDL 明文进 PG 日志。
- 所有服务只监听 127.0.0.1（PG 5432、PgBouncer transaction 6432 与 session 7432、Redis 6379，端口可在 env 改）。
- MUST NOT 把 `handover.md` / `projects/*.md` 内容打到 stdout（模型的回复也是一种 stdout）。
- MUST NOT 用 Read / Edit / cat / sed 触碰 `.pg-ops/`——所有读写经 `pgops-env.sh` / `pgops-fetch.sh` / `pgops-guard.sh` 三个工具脚本。
- Codex 宿主没有 deny 机制——只剩「脚本不打 stdout」与「人不 cat」两道防线；Claude Code 宿主下 `pgops-guard.sh` 落的
  `settings.json` deny 是第三道机械防线，但仅对 Read / Edit / Bash 识别出的 cat/head/tail/sed/重定向生效，不拦子进程读文件。
- `.claudeignore` 是消费方约定，Claude Code 官方文档无此机制，不算防线。

## 其它发行版

当前只有 `scripts/install-ubuntu.sh`。RHEL 系 / macOS 需要时另加 `install-<os>.sh`，参数与 env 同一份，`render.sh` 加一个选择。

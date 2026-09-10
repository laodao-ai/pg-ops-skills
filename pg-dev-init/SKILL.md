---
name: pg-dev-init
description: 在项目仓根一次跑完「给一个项目立 PostgreSQL 开发环境」：先自动调用 pg-dev-server 做前置检查（服务器装过就只落 env + 取交接文档，没装过才走装机），再生成建库脚本（库 + owner 角色 + scratch 库，幂等；角色经 PgBouncer auth_query 自动可登录，项目侧零 PgBouncer 配置），只需库名一项参数；默认由人上服务器执行，也可委托本 skill 经 ssh 代跑；也用于换密。用于「给项目建 pg dev 环境」「给项目建开发库」「新项目接开发数据库」「换开发库密码」。
---

# pg-dev-init —— 给一个项目立 PostgreSQL 开发环境（前置检查 → 引导 → 生成脚本 → 执行 → 交接连接串）

## 何时用

- 项目首次接入开发数据库服务器：建库、建 owner 角色、建 scratch 库。
- 换密：填 `DB_PASS` 重跑。
- 前置由本 skill 自动完成（⓪）：项目仓要有 `.pg-ops/pg-dev-server.env`（含 `SSH_TARGET`），没有就调 `pg-dev-server` 落下。
  目标机须跑过 **最新** `pg-dev-server`（PgBouncer 为 auth_query 模式），建库脚本会检查，旧版 userlist 模式会被拒。

**不做的事**：不装服务、不改 PgBouncer / Redis；不跑项目迁移、不灌数据、不改项目配置（那些留在消费项目的 `hack/`）。

## 流程

### ⓪ 前置检查：调用 pg-dev-server，不要自己复刻它的步骤

先看项目根有没有 `.pg-ops/pg-dev-server.env`：

- **有** → 用工具脚本读 `SSH_TARGET`（MUST NOT 用 Read / cat 直接打开这个文件——含口令的 env，走工具脚本）：

  ```bash
  SSH_TARGET="$(bash <skill-dir>/scripts/pgops-env.sh get .pg-ops/pg-dev-server.env SSH_TARGET)"
  ```

  直接进 ①。
- **没有** → 这个项目还没接入服务器。**在本 skill 内直接调用 `pg-dev-server` skill**（Claude Code 用 Skill tool，
  Codex 用 `$pg-dev-server`），把人给的 ssh 别名传过去，由它做「⓪ 起手判断」：
  - 它判出 **INSTALLED** → 它落 env + 取回 `.pg-ops/handover.md` 后返回，本 skill 接着进 ①。人只说了一句话，不必再触发第二次。
  - 它判出 **FRESH** → 服务器还没装。由它走完整装机（人跑 / 委托）；装机完成、探活通过后再回到本 skill 进 ①。
    装机需要人上服务器执行时，本 skill 停在这里等人说「装好了」再继续，MUST NOT 跳过装机直接建库。

MUST NOT 让人先自己去跑 `/pg-dev-server` 再回来——那是本 skill 的活。

### ① 引导收参（最少只要一个库名）

| 项 | 缺省 | 什么时候才问 |
|---|---|---|
| `DB_NAME` | 无，必填 | 先自己推一个提议再让人确认：依次看 `go.mod` 的 module 名 / `package.json` 的 name / 项目现有 dev 配置里的库名 / cwd 目录名，连字符转下划线，须匹配 `[a-z_][a-z0-9_]*` 且**不以 `pg_` 开头**（PG 保留该前缀给系统角色，而 owner 默认与库同名；`pg_skills` 这类名字要写成 `pgskills`）。提议时说明来源（「从 go.mod module `example-app` 推的」） |
| `DB_USER` | 同 `DB_NAME` | 不问 |
| `DB_PASS` | 留空：新建时服务器自动生成并记录在交接文档，已存在则保持不变 | 人要换密、或要指定口令时 |
| `SCRATCH_DB` | `<DB_NAME>_scratch` | 人明确不要时填 `none` |
| `CREATEDB` | 留空 / `0`：不动角色 | 人要该角色能自建 / 删测试克隆库时填 `1`（幂等，不收回） |
| `REDIS_DB` | 留空：自动分配（从 1 起跳过其它项目已用号，换密重跑沿用文档已分配的号） | 人要钉死某个编号时填数字（`0` 保留不可用） |
| `SSH_TARGET` | 从 `.pg-ops/pg-dev-server.env` 读 | 不问（⓪ 已保证文件存在） |

### ② 生成脚本

**生成前 MUST 先做**：在项目根执行 `pgops-guard.sh`，幂等确保 `.gitignore` / `.claudeignore` / `.claude/settings.json`
三处都挡住了 `.pg-ops/`（含口令，不能进仓、不能进模型上下文）：

```bash
bash <skill-dir>/scripts/pgops-guard.sh .
```

项目仓里只有自己一个库，不分层：env 放 `.pg-ops/pg-dev-init.env`，产物放 `.pg-ops/build/`（整个 `.pg-ops/` gitignore）。
用 `pgops-env.sh set` 写参数（MUST NOT 用 Edit / cat / sed 直接改这个文件）：

```bash
bash <skill-dir>/scripts/pgops-env.sh set .pg-ops/pg-dev-init.env --from <skill-dir>/pg-dev-init.env.example \
  DB_NAME=<库名> [CREATEDB=1] [REDIS_DB=<数字>]
bash <skill-dir>/scripts/render.sh .pg-ops/pg-dev-init.env .pg-ops/build/db-<DB_NAME>.sh
```

产物是一份自包含脚本（权限 700）。

### ③ 执行（默认人跑；人说「你来跑」再委托）

```bash
scp .pg-ops/build/db-<DB_NAME>.sh <host>:/tmp/
ssh -t <host> 'sudo bash /tmp/db-<DB_NAME>.sh; rm -f /tmp/db-<DB_NAME>.sh'
```

委托执行时用 Bash 跑这两行并原样带回输出；非零退出就停并贴错误。脚本会把自己装到服务器 `/opt/pg-ops/bin/pg-dev-init-<DB_NAME>.sh`，可原地重跑。
若消费仓已用 `pgops-guard.sh` 落了 `settings.json` 的 `Read(./.pg-ops/**)` deny，`scp .pg-ops/build/...` 这条命令的源参数
**可能**被一并拦下（Claude Code 官方文档未明确覆盖范围）——被拦即降级为「只打印给人跑」，MUST NOT 另造第四个工具绕过 deny。

脚本做的事：守卫（`PG_OPS_ROLE=dev`、root、5432 可达、PgBouncer 是 auth_query）→ 角色（不存在则建；存在且填了
`DB_PASS` 则改密；否则不动）→ 库与 scratch 库（已存在不碰数据）→ 知道口令时经 PgBouncer 真登录探活 → 写服务器交接文档 `/opt/pg-ops/projects/<DB_NAME>.md` → 打印连接串。

### ④ 交接

账号、口令、连接串都记录在服务器上，取回给项目管理者（走安全渠道；用 `pgops-fetch.sh`，MUST NOT 用
`ssh ... sudo cat` 把内容打进模型输出）：

**收尾提示（MUST）**：取回一份本地副本，最终回复里明确写出两处路径（内容本身 MUST NOT 出现在回复里）：

```bash
bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/projects/<DB_NAME>.md
```

> 项目库交接文档已生成（含口令，走安全渠道交给项目管理者，收进项目 secret 工具）：
> - 服务器：`/opt/pg-ops/projects/<DB_NAME>.md`，人也可登录服务器亲自 `sudo cat` 该路径
> - 项目仓副本：`.pg-ops/projects/<DB_NAME>.md`（已 gitignore；落点镜像服务器布局，一库一份不互相覆盖）

之后的事归消费项目自己，回复末尾提示这三件（只提示，MUST NOT 替项目改配置）：

1. 口令收进项目的 secret 工具，**项目 dev 配置里的库名 / 用户 / 口令换成这套新账号**（不要再用 `postgres` 超级用户——两个池口都拒绝它）；
   lib/pq 类驱动走 6432 要加 `binary_parameters=yes`。
2. 起隧道（命令在 `.pg-ops/handover.md` 第 3 节）。
3. 跑项目自己的迁移 / init。

## 查询（某项目的库账号是什么 / 这台机上有哪些项目库）

```bash
ssh <host> sudo ls /opt/pg-ops/projects/
bash <skill-dir>/scripts/pgops-fetch.sh <host> /opt/pg-ops/projects/<DB_NAME>.md
```

模型只取回到本地文件，不把内容打进回复；人自己 `cat .pg-ops/projects/<DB_NAME>.md`，或直接在服务器上 `sudo cat`。

## 幂等与安全边界

- 重跑不改已有库的数据；`DB_PASS` 留空时不改已有角色的口令。
- `PG_OPS_ROLE` 不是 `dev` 拒跑；库名 / 用户名只允许 `[a-z_][a-z0-9_]*`，且 owner 角色名不得以 `pg_` 开头（PG 保留前缀）。
- 参数校验在 **render 阶段（本机）** 就跑一遍——`render.sh` 以 `PG_OPS_VALIDATE_ONLY=1` 调 `provision.sh` 的守卫①，参数不合法就不出产物，不必等 scp + ssh 到服务器才发现。
- 含口令的 SQL 会话级关闭 `log_statement`。
- 一个项目一个库一个 owner；最小权限拆分（app DML / migrate DDL / readonly）见 `pg-roles`，不在本 skill。
- MUST NOT 把 `handover.md` / `projects/*.md` 内容打到 stdout（模型的回复也是一种 stdout）。
- MUST NOT 用 Read / Edit / cat / sed 触碰 `.pg-ops/`——所有读写经 `pgops-env.sh` / `pgops-fetch.sh` / `pgops-guard.sh` 三个工具脚本。
- Codex 宿主没有 deny 机制——只剩「脚本不打 stdout」与「人不 cat」两道防线；Claude Code 宿主下 `pgops-guard.sh` 落的
  `settings.json` deny 是第三道机械防线，但仅对 Read / Edit / Bash 识别出的 cat/head/tail/sed/重定向生效，不拦子进程读文件。
- `.claudeignore` 是消费方约定，Claude Code 官方文档无此机制，不算防线。

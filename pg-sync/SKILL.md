---
name: pg-sync
description: 从生产库拉快照同步到开发库：schema 阶段与 data 阶段分开，生产侧脚本 + 独立 env 一起复制到生产机执行（模型不读生产 env、不接触任何敏感信息，ADR-0001），dev 侧收快照、装载并 rename 切换。用于「从生产拉快照到开发库」「同步生产数据到 dev」「pg-sync」。
---

# pg-sync —— 从生产库拉快照同步到开发库

## 何时用

- 项目需要用生产的真实 schema（和/或裁剪过的数据）刷新开发库，而不是只跑迁移脚本。
- schema 阶段可单独跑：拿到生产真实 DDL，与开发库迁移产物做 diff。
- data 阶段可反复跑：只要 schema 指纹没变，随时重新拉一份新数据，不用重做 schema。

**前置**：项目已用 `pg-dev-init` 建过 dev 库（本 skill 只管「同步进去」，不建库、不管角色）。

## 边界（先看这条）

**模型 MUST NOT 读生产侧 env**（`.pg-ops/pg-sync/pg-sync-prod.env`，以及生产机上同名文件），
**MUST NOT 要求人把生产机上的任何输出贴回**当前会话——身份核对、锁槽账、磁盘账全部由脚本在
生产机上自行完成并只打印在生产机终端。这是 [ADR-0001](../docs/adr/0001-prod-side-scripts-are-bundles-model-never-reads-prod-env.md)
的硬约束，不是建议。

模型只做三件事：① 引导人填开发机 `pg-sync.env`（不含任何生产敏感值）；② 渲染出 bundle 目录
（脚本 + env 模板，敏感项留空）供人 `scp` 到生产机；③ 渲染 dev 侧自包含脚本供人上 dev 机跑。
生产机上填 env、跑脚本，全部由人完成（生产侧无委托——本 skill 不会替人登生产机）。

想让模型少看见这类目录，消费仓可在 `.claude/settings.json` 加一条 Read deny（可选，纵深防御，
模型本就不会主动读）：

```json
{ "permissions": { "deny": ["Read(.pg-ops/pg-sync/**/*.env)"] } }
```

## 一次性准备

两条传输路线二选一（也可以都配，按需切换），配好之后每次同步复用：

### 路线 A：rsync（生产、dev 同内网或已打通网络时用）

1. 生产机首次跑 `30-transport-rsync.sh`：没有 key 就生成一对 `ed25519`，打印公钥后退出（不传输）。
2. 把打印的公钥贴进开发机 `.pg-ops/pg-sync.env` 的 `RSYNC_SRC_PUBKEY`；渲染并上 dev 机跑
   `receive-setup.sh`：建受限收件用户 `pgsync`（`rrsync -wo` 只能写一个目录，无 shell 权限以外能力）、
   建 `incoming/`、按需放行 ufw 22 端口；结尾打印 dev 主机的 `ssh-keyscan -t ed25519` 一行。
3. 把这行贴进 `RSYNC_DEST_HOSTKEY`（渲染进生产 env）——传输脚本据此写死 `known_hosts`
   （`StrictHostKeyChecking=yes`，不信任任意应答方）。再跑一次 `30-transport-rsync.sh` 即开始真正推送。

### 路线 B：OSS（生产、dev 网络不可达，经阿里云对象存储中转）

**bucket 落在 dev 所在云与地域**（不是生产所在云）——推的一腿走公网只付一次出流量，拉的一腿走
dev 侧内网免费且不受入带宽限制。生产在哪家云都行：生产侧只需要 `ossutil` 静态二进制 + 出方向
443，不依赖生产所在云的任何设施；以后 dev 换云，只需新增一份 `30-transport-<provider>` 脚本对，
不改本 skill 其它任何部分。

人在控制台准备（模型不代做，也拿不到 AccessKey）：

- 一个 bucket，建议开生命周期规则（如 7 天自动删除），避免快照堆积产生费用与合规风险。
- 一个**只写** RAM 子账号（`PutObject`，仅这个 bucket 的这个前缀），生产机上 `ossutil config` 配好。
- 一个**只读** RAM 子账号（`GetObject`/`ListObject`，同前缀），dev 机上 `ossutil config` 配好。
- 两个 endpoint：生产侧填外网 endpoint（`OSS_ENDPOINT_UPLOAD`），dev 侧填内网 endpoint
  （`OSS_ENDPOINT_DOWNLOAD`）——两者不同，别填反。

`pg-sync.env` 里填好 `OSS_BUCKET` / `OSS_PREFIX` / 两个 endpoint 即可，AccessKey 永远不进 env、不进仓。

## schema 阶段

```
生产机：00-inventory（首跑打印 system_identifier，填入 EXPECT_SYSID）
        → 10-dump-schema（身份核对 + 锁槽账 → pg_dump --schema-only → 指纹 → manifest）
        → 30-transport-rsync 或 30-transport-oss（推到 dev）
dev 机：receive-setup（仅 rsync 路线首次要跑）/ fetch-oss（拉取 + sha256 校验）
        → restore-schema（建 <库>_sync → 预建扩展 → SET ROLE 装 schema → 写 sync.json）
```

`restore-schema` 之后 `<库>_sync` 里的对象全部归 `DB_OWNER`（即项目 `pg-dev-init` 建的库 owner 角色）；
不需要 owner 口令，也不需要 `REASSIGN OWNED`。

## data 阶段

```
生产机：00-inventory（同一份，解析 DATA_RULES → plan.tsv，只出计划不干活）
        → 20-dump-data（读 plan → full 走 pg_dump -Fd -t 清单；window 普通表走逐表 COPY → manifest）
        → 30-transport-rsync 或 30-transport-oss
dev 机：receive-setup / fetch-oss（同 schema 阶段）
        → restore-data（磁盘账 → sha256 → 指纹对 sync.json → 装载 → setval → ANALYZE → 钩子 → rename 切换 → 报告）
```

### `DATA_RULES` 怎么写

在开发机 `pg-sync.env`（与生产机 env 是同一段文本，渲染时自动同步）里，每行一条规则：

```
<表模式>            <策略>  [参数…]
logs.*              window created_at   90d     # 声明式分区：挑与窗口相交的叶子
data.n_*_2026       window created_time 30d     # 手工分表：逐表 COPY WHERE
data.n_*            none                        # 其它年份的手工分表整体跳过
public.big_events    sample 50                  # 手工分表按名字抽 50 张，配合上一行的 window
*                    full
```

- 先匹配先赢，`#` 起注释；模式用 `pg_dump -t` 通配（`schema.table`，`*` `?`，无 schema 视为 `public`）。
- `N` 只接受 `d`（天）或 `h`（小时）——`m`（分钟）没有意义，故意不支持，避免和「月」混淆。
- 「只要今年的分表」**不要**指望 `window` 表达任意日期范围——`window` 只表达「滚动窗口」，用表名模式
  直接选（`data.n_*_2026 full`）。
- **缺省整库 `* full`**：不写任何规则时同步整库全部数据。这是故意的保守缺省——遗漏一条规则的后果
  是「多同步了几张表」（可接受），而不是「该同步的表悄悄被跳过」；要裁剪就显式加规则。

### `plan.tsv` 与 RED 怎么处置

`00-inventory` 只读盘点，产出人可读的 `plan.tsv`（列：`schema table strategy detail est_bytes flag reason`），
不碰任何数据。`flag=RED` 有三种：

| reason | 意思 | 处置 |
|---|---|---|
| `no-index-on-<col>` | `window` 用的时间列没有 btree 首列索引，且表 > 1 GB，顺序扫代价太高 | 给该表加索引，或改规则用 `none`/`sample` |
| `too-big-for-window` | 同上系列，表过大 | 同上 |
| `lock-budget` | 待锁表数 × 1.2 超过可用锁槽 | 收窄规则排除整个 schema，或等重启窗口调大 `max_locks_per_transaction` |

`RED` 只影响 `20-dump-data`（拒跑，三段式提示）；`00-inventory` 本身只出计划，不会因为 RED 失败。

## dev 侧人跑为缺省，生产侧永远人跑

- **dev 侧**（`receive-setup` / `fetch-oss` / `restore-schema` / `restore-data`）：默认打印命令由人上
  dev 机执行；人明确说「你来跑」才委托 skill 经 ssh 代跑。
- **生产侧**（`00-inventory` / `10-dump-schema` / `20-dump-data` / `30-transport-*`）：**没有委托这一说**。
  bundle 复制过去之后，全部由人亲自在生产机上执行——模型不登生产机，也不看生产机的输出。

## 生产影响

每个生产侧脚本起手都过一遍：身份核对（拒绝在错的机器/错的库上跑）、只读会话（`default_transaction_read_only=on`，
脚本内没有任何写库 SQL）、锁槽账（不够就拒跑）、磁盘账（不够就拒跑）、`--lock-wait-timeout`（排不到队就
超时退出，不无限期等）、`nice -n 19 ionice -c3`。

**如实说明 `nice`/`ionice` 的作用范围**：它们只限速 `pg_dump` / `psql` / `zstd` 这些**客户端**进程本身的
CPU / IO 调度优先级，**不影响** PostgreSQL 服务端 backend 进程的资源占用——服务端那边的影响，靠的是
另一套机制：`-t` include 清单只锁计划里的表（不扫无关表）、`window` 普通表逐表短事务（不持有长事务）、
`lock_timeout` 不让请求无限排队、以及人自己选错峰时段跑。不要把 `nice`/`ionice` 当成服务端限速手段。

## `SYNC_SAME_CLUSTER_OK`：仅供自测

dev 侧默认拒绝「源库和目标库是同一个 PostgreSQL 集群」（比对 `system_identifier`）——这是防止把生产
错当 dev 覆盖的最后一道闸。唯一的开口是在**开发机自己的** `pg-sync.env` 里显式设
`SYNC_SAME_CLUSTER_OK=1`，用来在一台机器上左手倒右手自测（例如从 `pgops_smoke` 同步到
`example_dev`）。开这个口子仍然同时要求 dev 标记（`/opt/pg-ops/handover.md` 存在 + `PG_OPS_ROLE=dev`）
和目标库名 ≠ 源库名——同集群同名会直接覆盖源库，永远拒绝。**对接真生产时这一项永远留空。**

## 跨法域合规

快照是生产真实数据，一旦落到 dev 机（哪怕经 OSS 中转 bucket 只是短暂落脚）就发生了一次数据传输/
出境。是否合规（个人信息保护法、行业数据出境要求等）由人自己判断——本 skill 不做法律判断，
只保证传输过程本身安全（只写/只读凭据分离、传输凭据不落 stdout、OSS bucket 建议配生命周期自动清理）。

## 查询

同步完成后的报告与状态都在 dev 机的 `/opt/pg-ops/`，不用重跑脚本：

```bash
ssh <host> sudo cat /opt/pg-ops/projects/<库名>-sync.md   # 本次同步报告：策略/行数表、耗时、上一次 sync_id、回滚命令
ssh <host> sudo cat /opt/pg-ops/projects/<库名>.sync.json # 当前状态：schema/data 指纹、切换时间
```

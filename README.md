# pg-ops

独立、全局安装的 **PostgreSQL 运维引擎仓**：开发数据库服务器装机、生产库备份与恢复、生产→开发同步、
监控与告警、最小权限角色与审计。从一个 Go 服务的生产运维实践中抽出（2026-09-04）。

`setup.sh` 把各 skill symlink 到 `~/.claude/skills/` 与 `~/.codex/skills/`，任何 PG 项目全局可用。

**边界判据（唯一一条）**：不知道消费项目存在的东西才在这里。凡是引用某个项目的二进制、
schema 名、CLI 子命令、制品布局的，留在那个项目的 `hack/`，通过薄包装调用本仓。

本仓是**引擎**：消费项目经 `.pg-ops/`（owner 口令，模型不碰，ADR-0002）这一条接缝接入。同时它也是
**自己的消费仓**（2026-09-09 拍板：「测试也是消费」）——有自己的开发/测试库、自己的 `.pg-ops/`，
用自己的 skill 做自己的开发与测试。这与上面那条边界判据不矛盾：判据约束的是 **skill 的内容**
（引擎一行都不能提某个消费项目的名字与布局），不是仓里有没有库——引擎自己吃狗粮是对的。

## Skills

| skill | 状态 | 做什么 | 源需求 |
|---|---|---|---|
| `pg-dev-server` | 首版 | 引导填参 → 生成自包含装机脚本 → 人跑或委托跑：PostgreSQL 18 + PgBouncer（transaction / session 两实例按端口分，auth_query）+ Redis，全部回环监听；只装服务器基础环境 | T82 / T83「开发服务器需求」 |
| `pg-dev-init` | 首版 | 给一个项目立 PG 开发环境：自动调 `pg-dev-server` 做前置检查（装过只落 env，没装才装机）→ 建库 + owner 角色 + scratch 库（只需库名；角色经 PgBouncer 自动可登录）→ 交接连接串；也用于换密 | T83「多项目共用」 |
| `pg-sync` | 首版 | 生产→开发快照：schema / data 两阶段，生产侧脚本 + 独立 env 一起复制到生产机执行（模型不读生产 env，ADR-0001）、只读 dump → rsync/OSS 传输 → dev 侧装载并 rename 切换；目标非生产核验；项目收尾钩子由消费方提供 | T83 通用段 |
| `pg-ops-upgrade` | 首版 | 升级本机运行 checkout `~/.skills/pg-ops-skills`：pull → setup → 显示版本 | — |

规划中的 skill（`pg-backup` / `pg-tune` / `pg-prod-server` / `pg-sizing` / `pg-monitor` / `pg-roles`）、
实施顺序、卡点与规格来源，见 **[`docs/skills-roadmap.md`](docs/skills-roadmap.md)**——那是 skill 规划
的唯一真相源，新增 / 改名 / 去重先在那里落位。

## 安装

```bash
git clone https://github.com/laodao-ai/pg-ops-skills.git ~/.skills/pg-ops-skills   # 运行 checkout（真 clone，不是软链）
bash ~/.skills/pg-ops-skills/setup.sh            # 幂等；Unix symlink，Windows 拷贝
```

之后升级用 `/pg-ops-upgrade`（pull → setup → 显示版本）。开发改动在另一份开发 checkout 里做、push 后
在运行机跑升级；运行 checkout 只读，勿在其中改代码。

## 使用

三个 skill 的总览（我该用哪个 · 按什么顺序 · 卡住了在哪一格，含流程图）见
**[`docs/skills-guide.md`](docs/skills-guide.md)**。

具体怎么做（该说什么、会被问什么、文件落在哪）见 **[`docs/quickstart.md`](docs/quickstart.md)**，按三种场景：
搭一台新开发服务器 → 给一个项目立 PG 开发环境（最常见，在项目仓根说「给这个项目建 pg dev 环境」，一句话跑完前置检查与建库） → 换密 / 查账号 / 刷新文档。

## 目录

```
setup.sh              全局安装（symlink 到两宿主）
pg-dev-server/         服务器基础环境装机（SKILL.md + env.example + scripts/ + templates/handover.md 交接文档模板）
pg-dev-init/           给一个项目立 PG 开发环境：前置检查 + 建库 / 角色（同结构，scripts/provision.sh + templates/project.md）
pg-sync/               生产→开发快照同步：scripts/lib.sh 两侧共用 + scripts/prod|dev/ 分脚本 + render.sh bundle|dev 两种产物
pg-ops-upgrade/        运行 checkout 升级三连（pull → setup → 显示版本）
pg-ops-shared/         跨 skill 共用的 shell 库（Unix 下留仓内、经 4 个 skill 的软链可达；
                        Windows 下额外独占拷贝到宿主，见 ADR-0003）：
                        diag/ 只读诊断脚本（render.sh 内嵌上服务器）；
                        pgops-env.sh / pgops-fetch.sh / pgops-guard.sh / pgops-lib.sh dev 侧模型不碰口令的工具脚本（ADR-0002）
tests/                 pytest：setup.sh 安装逻辑 + pgops-fetch.sh 取回逻辑（离线，秒级）
docs/                  runbook（人读）与规划文档
  skills-roadmap.md     规划唯一真相源：目标态 / 规划 skill / 顺序 / 规格来源
  skills-guide.md       skill 总览：接缝 / 执行流程 / 安全边界（md + 同内容 html）
  quickstart.md         快速上手：三种场景（搭新服务器 / 项目接入已有服务器 / 换密与查账号）
  runbook-pg-repack.md  表膨胀处置（pgstattuple 量化 + pg_repack 在线压缩）
  runbook-pg-major-upgrade-16-to-18.md  存量 16 生产机升 18（pg_upgrade 原地，含 TimescaleDB 约束）
  adr/                   架构决策记录：0001 生产侧 bundle 形态、0002 dev 侧模型不碰 .pg-ops/、0003 各仓装到带仓名前缀的独占目录
  scripts/               只读诊断脚本已迁至 pg-ops-shared/diag/；本目录只留 pgbouncer-second-instance.sh
                         （既有机专用，唯一会改配置）
LICENSE                Apache-2.0
```

## 消费方接缝（以一个 Go 服务为例）

- `hack/sync-prod-to-dev.sh` = 调 `pg-sync` + 项目三步收尾（跑迁移 / rotate-secret / 重放 fixture）。
- `hack/backup-db.sh` / `restore-db.sh` / `ssh-tunnel.sh` 后续搬入 `pg-ops-shared/`，原位置留指针。
- 规则文档 `openspec/rules/production-ops.md` 留在项目，引用本仓 skill 做操作面。

## 许可

Apache-2.0，见 [LICENSE](./LICENSE)。

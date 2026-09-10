# dev 侧模型同样不接触 `.pg-ops/`：读写只经 pg-ops 自带的工具脚本，消费仓落 `Read` deny

ADR-0001 把「模型不读敏感值」定在生产侧（bundle 形态）。dev 侧的 `pg-dev-server` / `pg-dev-init`
当时仍由模型 Read env 内联渲染、`ssh <host> sudo cat` 取交接文档——2026-09-07 example-app 的
测试基础设施目标态（`docs/test-infra-target-state.md` §4.7）指出这条链路在源头就漏：建库脚本把新口令
打到 stdout，skill 步骤把含 postgres 超管与 Redis 口令的交接文档 cat 进模型上下文。本 ADR 把 0001 的
原则延伸到 dev 侧：**口令与交接文档只存在于服务器 `/opt/pg-ops/` 与消费仓 `.pg-ops/` 两处文件里，
模型的上下文不是其中之一。** 落地形态：① 脚本 stdout 只打「已写入 <路径>」；② skill 对 `.pg-ops/`
的一切读写经 `shared/pgops-env.sh`（get 只回显一个非口令键 / set 改已知键 / show 打参数段口令打星）
与 `shared/pgops-fetch.sh`（远端文档取回到本地文件，stdout 只打路径）两个子进程完成，模型不用
Read / Edit / Write，也不用裸 cat / sed；③ skill ② 步在消费仓 `.claude/settings.json` 落
`Read(./.pg-ops/**)` deny。选这个形态的直接依据是 Claude Code 官方文档：`Read` deny 连带拦
Edit / Write、Bash 里被识别的文件命令（cat / head / tail / sed）与 `>` `<` 重定向目标，只放过
「自己打开文件的子进程」——deny 一落地，skill 原来的 Read / Edit / 重定向路径全会被拦，
工具脚本是唯一既合规又可审计（读什么、打什么写死在脚本里）的路径。

## Considered Options

- **全目录 `Read` deny + 工具脚本子进程（选中）**：模型零接触；`pg-dev-server.env` 有三个可填口令的键，
  整目录 deny 才没有洞。代价 = `shared/` 多两个小脚本，SKILL.md 的几步从「Read / Edit」改成「调工具」。
- **deny 缩到 `*.md` / `build/` / `pg-dev-init.env`，让 `pg-dev-server.env` 可 Read**：省掉 get 工具，
  但该 env 的 `PGB_AUTH_PASS` / `REDIS_PASS` / `PG_SUPER_PASS` 一旦被人填过就进上下文。未选。
- **保留全目录 deny，用 `bash -c 'sed -i …'` 绕过去改 env**：能跑，但是在教模型绕防线，与「模型不碰」
  的形态相悖，且绕行命令散落各步不可审计。未选。
- **另加 `Bash(cat .pg-ops/*)` deny**：官方文档明确 `Read` deny 已覆盖被识别的 Bash 文件命令，
  Bash 前缀规则只匹配字面前缀（`cat ./.pg-ops/x` 就不中），冗余。未选。

## Consequences

- dev 侧 skill 需要 `.pg-ops/` 里某个非敏感单值（如 `SSH_TARGET`）时，一律 `pgops-env.sh get`；
  需要交接文档副本时，一律 `pgops-fetch.sh` 或把命令打印给人跑。SKILL.md 明写
  **MUST NOT 把 `/opt/pg-ops/handover.md`、`projects/*.md` 内容打到 stdout**。
- 以后新增 dev 侧 skill（pg-backup 的 dev 端、pg-roles 等）沿用本形态，不再逐个论证。
- `.claudeignore` 按消费方约定照加，但 Claude Code 官方文档无此机制，MUST NOT 把它当防线写。
- Codex 宿主没有 deny 等价物：那里只有「脚本不打 stdout」与「人不 cat」两道，SKILL.md 如实写。
- 机制边界：`Read` deny 放过自己打开文件的子进程，模型仍能写一个脚本去读 `.pg-ops/`。这不是本仓能堵的，
  接受；防线是 deny + SKILL 条款 + 脚本不打 stdout 三道叠加，不是任何一道单独保证。

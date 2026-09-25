# 各仓安装到带仓名前缀的独占目录，不再共用 `shared/`

拆分后的 `pg-ops` 与 `db-llm` 两仓各自把工具脚本装到同一批宿主 skills 目录（`~/.claude/skills/`、
`~/.codex/skills/`）。Windows（Git Bash / MSYS / Cygwin）下 symlink 会静默退化成不随 `git pull`
更新的拷贝，因此 Windows 分支一律走拷贝；两仓的工具脚本原先都落在同名的 `shared/`，Windows 拷贝
模式下只能靠「合并拷贝」（逐文件覆盖同名、不整份替换）避免互相清空对方文件，代价是所有权判断散在
文件名层面、任何一方新增文件都可能与另一方撞名。本 change 把仓内目录从 `shared/` 改名为
`pg-ops-shared/`，Windows 落点同步改名为独占目录，安装语义与四个 skill 目录完全一致（自属整份
替换 / 非自属 fail-loud / 软链一律拒装），`setup.sh` 里不再有针对共用目录的特例分支。

## Considered Options

| 候选 | 系统镜 | 用户镜 | 开发循环镜 |
|---|---|---|---|
| A 仓内与落点同名改为 `pg-ops-shared`（选中） | 落点独占，删掉合并拷贝特例，一条路径两种安装通用 | Windows 用户重跑 setup 后多一行旧目录提示 | 路径规则只有一条，shim 不写回退 |
| B 仓内保留 `shared/`，只改 Windows 落点 | 两种安装路径不一致，每个 shim 要「先试 A 再试 B」 | 同 A | 每加一个 shim 都要记住双路径 |
| C 维持共用 `<宿主>/shared` + 合并拷贝 | 所有权标记冲突，他仓先装会导致对方拒装 | 装机顺序决定成败 | 两仓要共同维护文件名互斥 |

主次判定：系统镜最重要。C 在系统层就有确定的故障（所有权标记冲突导致后装的仓拒装），B 把复杂度
推给每个 shim（每加一处引用都要记住两条候选路径）。A 的代价只是一次性改名，因此选 A。

## Consequences

- Unix 下 `pg-ops-shared` 不建宿主软链，`../../pg-ops-shared` 全部经仓内相对路径解析，与四个
  skill 目录的现有布局一致。
- Windows 下 `pg-ops-shared` 走与四个 skill 目录相同的 `install_skill` 语义：自属（含本仓
  `.pg-ops` 标记）整份替换；非自属（无 `.pg-ops` 标记；标记只看是否存在，不校验内容）fail-loud，三行 problem/cause/fix
  报告；已存在的软链一律 fail-loud，不接管、不解引用。
- 旧 `<宿主>/shared` 目录不自动删——可能仍含另一个拆分仓（`db-llm`）拷入的文件。Windows 下检测到
  其中含本仓旧标记 `.pg-ops` 时打印一行残留提示（含路径、「旧安装残留」、「确认其中无他仓仍在
  使用的文件后可手动删除」），不删不改，不影响退出码。
- `setup.sh` 里 `pg-ops-shared` 与四个 skill 走同一份 `install_skill` 函数，不再有独立的「合并
  拷贝」代码路径。本 change 只改本仓；`db-llm` 仓是否与何时跟进同一约定不在本 change 范围内。

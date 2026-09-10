# 生产侧脚本是「脚本 + 独立 env」的 bundle，模型永远不读生产 env

pg-ops 的 dev 侧 skill（pg-dev-server / pg-dev-init）用 `render.sh` 把 env 内联进一份自包含脚本，
上传一个文件即可执行——代价是模型必须读 env 才能内联。2026-09-07 设计 pg-sync 时，人明确要求
「大模型不应该读 env 文件、不应该读这些敏感信息」「必须保证生产服务器的安全」。生产侧从此改为
bundle 形态：模型只生成 env **模板**（非敏感项填好、敏感项留空并注释取值方法）与工具脚本，人把整个
目录复制到生产机、在生产机上填空，脚本 `source` 同目录 env 自行完成身份核对与前置检查；模型
MUST NOT 读 `.pg-ops/<skill>/*.env`，MUST NOT 要求人把生产机上的输出贴回。后续所有生产侧 skill
（pg-backup、pg-prod-server 等）沿用本形态。

## Considered Options

- **bundle 形态（选中）**：模型零接触生产敏感值；身份核对（库名 / `system_identifier` / 主机名）由
  脚本在生产机比对人填的期望值。代价 = 仓里两种交互形态并存（dev 侧 render 内联、生产侧 bundle），
  上传从一个文件变成一个目录，`render.sh` 多一个分支。
- **沿用 render 内联单文件**：上传最简单，但模型必须读 env，违反人的硬要求。未选。
- **模型读 env 但「承诺不外泄」**：承诺不可机械核验，且 env 已进模型上下文。未选。

## Consequences

- 生产侧脚本的所有前置检查（身份、只读、资源账）必须自包含在脚本里，不能依赖模型在渲染期算好。
- 消费仓的 `.pg-ops/<skill>/` 目录整体 gitignore；SKILL.md 明写模型禁读该目录下 `*.env`，
  并建议消费仓在 `.claude/settings.json` 加 Read deny（与 T58 P4 同线）。
- 以后新增生产侧 skill 时，先按本形态设计，不再逐个重新论证。

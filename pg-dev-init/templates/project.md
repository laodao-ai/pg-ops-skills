# 项目开发库交接：{{DB_NAME}}

生成时间：{{GENERATED_AT}}。由 pg-ops/pg-dev-init 建库脚本写在服务器 `{{PG_OPS_DIR}}/projects/{{DB_NAME}}.md`，重跑（如换密）会更新。
服务器本身的信息（隧道、Redis 口令、安全配置）见 `{{PG_OPS_DIR}}/handover.md`。**本文含口令，只经安全渠道传递，不要提交到任何仓库。**

## 账号

| 项 | 值 |
|---|---|
| 库 | `{{DB_NAME}}` |
| scratch 库 | `{{SCRATCH_DB}}`（可炸的空库，排练迁移用） |
| 用户 | `{{DB_USER}}`（库 owner） |
| 口令 | `{{DB_PASS}}` |
| CREATEDB | {{CREATEDB_STATE}}（是 ⇒ 该角色可 CREATE/DROP 自己建的库，测试克隆库用；env CREATEDB=1 授予，不收回） |
| Redis db | `{{REDIS_DB}}`（项目专属编号，0 保留给人手工探查；换密重跑不变；redis.conf databases 缺省 16） |

## 连接串（服务器侧地址；开发机起隧道后端口相同）

| 用途 | 连接串 |
|---|---|
| 应用 / 集成测试（PgBouncer transaction 池，**默认**） | `postgres://{{DB_USER}}:{{DB_PASS}}@127.0.0.1:{{PGB_PORT}}/{{DB_NAME}}?application_name=<服务名>&binary_parameters=yes` |
| 要会话级特性又经池子（PgBouncer session 池） | `postgres://{{DB_USER}}:{{DB_PASS}}@127.0.0.1:{{PGB_SESSION_PORT}}/{{DB_NAME}}` |
| 迁移 / pg_restore（直连） | `postgres://{{DB_USER}}:{{DB_PASS}}@127.0.0.1:5432/{{DB_NAME}}` |
| scratch 库（直连） | `postgres://{{DB_USER}}:{{DB_PASS}}@127.0.0.1:5432/{{SCRATCH_DB}}` |

三个入口是同一个库、同一个账号，只差端口。transaction 池不保证事务之间是同一个服务端连接，所以 `SET` 会话变量、
会话级 advisory lock、`LISTEN` 订阅、逻辑复制 / CDC、SQL 级 `PREPARE / EXECUTE` 跨事务、跨事务临时表都不可靠（驱动的协议级
prepared statement 可以用）；碰到这些换 session 池口，迁移与批量导入走 5432 直连。

transaction 池连接串尾的 `binary_parameters=yes` **是 lib/pq 专有参数**（GoFrame/gogf `pgsql` 驱动即 lib/pq）：不加它，
带参数查询在这个口上会报 `unnamed prepared statement does not exist`；其它驱动（pgx / JDBC / npgsql / psycopg3 / asyncpg
等）不需要这个参数，可以去掉。`application_name` 换成本项目的实际服务名，用于连接归因。

应用侧连接池（`maxOpen` / `maxIdle` / 生命周期 / `application_name`）的完整 MUST/SHOULD 契约与验收方法见
`handover.md` 第 3 节「应用侧连接池契约」，完整对比与判断顺序见同节表格。

## 项目侧要做的

1. 口令收进项目的 secret 工具，写进 dev 环境层配置；不要明文进仓。
2. 起隧道（命令见 `handover.md` 第 3 节），跑项目迁移与 init。
3. 换密：在开发机把 `DB_PASS` 填进该项目的 `pg-dev-init.env` 重新渲染并执行，本文随之更新。
4. 原地重跑（幂等）：`sudo bash {{PG_OPS_DIR}}/bin/pg-dev-init-{{DB_NAME}}.sh`。

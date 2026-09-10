# {{DB_NAME}} 同步报告

**本文件 MUST NOT 含口令 / 凭据 / 主机名 / IP**（收尾前自检：`grep -E 'PASS|AccessKey|IP'` 应为空）。

生成时间：{{GENERATED_AT}}　sync_id：{{SYNC_ID}}　上一次 sync_id：{{PREV_SYNC_ID}}

## 源信息

- 生产库：{{SRC_DB}}（身份已在 restore-schema / restore-data 阶段核对过，本报告不回显主机名 / IP）
- 生产 PostgreSQL 版本：{{SRC_PG_VERSION}}
- schema_sha256：{{SCHEMA_SHA256}}

## 每表策略与行数

| schema | table | 策略 | 装载后行数 |
|---|---|---|---|
{{TABLE_ROWS}}

## 装载统计

- 禁用触发器的表数（pg_restore --disable-triggers，即 full 清单表数）：{{DISABLED_TRIGGERS_COUNT}}
- setval 的序列数：{{SETVAL_COUNT}}

## 各步耗时（秒）

| 步骤 | 耗时 |
|---|---|
| 守卫 + 校验 | {{T_GUARD}} |
| pg_restore -Fd（full 清单） | {{T_RESTORE}} |
| COPY 窗口装载 | {{T_COPY}} |
| setval + ANALYZE | {{T_ANALYZE}} |
| 钩子（POST_RESTORE_SQL / POST_RESTORE_HOOK） | {{T_HOOKS}} |
| 切换（rename） | {{T_SWITCH}} |

## 切换结果

{{SWITCH_RESULT}}

## 回滚命令（如需手动切回上一版本）

```
{{ROLLBACK_CMD}}
```

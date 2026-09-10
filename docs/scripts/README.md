# 既有机专用脚本

只读诊断脚本已迁至 `shared/diag/`（`cpu-phase.sh` / `conn-storm.sh` / `pgss-delta.sh` / `pg-mem.sh` /
`cpu-attrib.sh`，随 `pg-dev-server/scripts/render.sh` 内嵌上服务器），用法与排查顺序见
[`shared/diag/README.md`](../../shared/diag/README.md)。

本目录只留 `pgbouncer-second-instance.sh`：**唯一会改配置的脚本**，在已有单实例 PgBouncer 的机器上
再起一个第二实例（另一端口、另一池模式；复制 ini、派生 systemd 单元）。典型用法：既有实例是 session
模式，用它起一个 transaction 实例，服务证明兼容后逐个切过去。幂等，不碰现有实例。只服务「既有单实例机」这一种场景，pg-ops 自装的机器
天生两实例，不需要它。

用法：`sudo ./pgbouncer-second-instance.sh 7432 transaction 10`

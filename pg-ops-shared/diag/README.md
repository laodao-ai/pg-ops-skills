# 诊断脚本

排查一次生产 CPU 打满问题时现写的，全部**只读**，
不改任何配置、不写任何业务表。全部在目标机上以 `root` 跑（要读 `/proc/<pid>/stat`
和 `/etc/pgbouncer/`），分析部分用 `python3`（Ubuntu 自带）。随 `pg-dev-server/scripts/render.sh`
整目录内嵌（tar.gz + base64），装机时解到服务器 `/opt/pg-ops/bin/diag/`，与装机脚本同一生命周期。

**按相位分桶是三个脚本的共同设计**：每秒采一次，按「分钟内第几秒」归档，自动切出峰期
与谷期做差。所以**不用卡时间点**，随时起跑即可——周期性负载用任何跨相位的平均值去测
都会得到错误结论（案例 9.1）。

| 脚本 | 用在什么时候 | 用法 |
|---|---|---|
| `cpu-phase.sh` | CPU 有周期性尖峰，不知道是谁吃的。**排查第一步永远是这个** | `./cpu-phase.sh 300` |
| `conn-storm.sh` | 上一个显示 `system%` 高于 `user%`、且进程级归因率很低 | `BOUNCER_PORT=6432 PGBOUNCER_PASS=xxx ./conn-storm.sh 300` |
| `pgss-delta.sh` | 确认某条 SQL 现在的真实耗时（累计均值会被历史稀释） | `./pgss-delta.sh 300 25 [库名]` |
| `pg-mem.sh` | 上了连接池之后内存开始涨。区分共享缓冲区 / 后端私有 / 文件缓存 | `./pg-mem.sh` |
| `cpu-attrib.sh` | `pg_stat_statements` 给的 CPU 与监控曲线对不上，要把差额拆成「不是 postgres 吃的 / 是 postgres 但不是 SQL / 窗口不一致」 | `./cpu-attrib.sh 60 12` |
| `pg-conn-audit.sh` | 一次性确认「应用走了池还是直连、每个连接干了几个事务」。装机末尾自动跑一次（只报告，5 秒窗口），项目接入后可随时重跑 | `sudo ./pg-conn-audit.sh 10` |
| `pgb-console.sh` | 想看 PgBouncer 某实例的 `SHOW POOLS` / `SHOW STATS`，又不想翻 `userlist.txt` 找口令 | `sudo ./pgb-console.sh` 或 `sudo ./pgb-console.sh 7432 'SHOW STATS'` |

`pgbouncer-second-instance.sh`（**唯一会改配置的脚本**，在已有单实例 PgBouncer 的机器上再起第二实例）只服务
「既有单实例机」这一种场景，仍留在 `docs/scripts/`，不随本目录内嵌，见 `docs/scripts/README.md`。

## 排查顺序

```
cpu-phase.sh
   │
   ├─ system% > user%，进程级归因率低  ──▶  conn-storm.sh（连接风暴）
   ├─ 某个非 postgres 进程峰谷差最大   ──▶  尖峰不在数据库里
   └─ 某个后端 + 某条 SQL 峰谷差明显   ──▶  pgss-delta.sh（那条 SQL 现在多快）

上池之后内存上涨 ──▶ pg-mem.sh（多半是 relcache 累积，先看 MemAvailable 再决定要不要动）

想知道「走池还是直连、池有没有真的摊薄连接」──▶ pg-conn-audit.sh（装机末尾已自动跑过一次）
想直接查某个 PgBouncer 实例的池状态又不想翻口令 ──▶ pgb-console.sh
```

细节与判据见案例文档 **9.1 测量方法论**。

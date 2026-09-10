#!/usr/bin/env bash
# pg-sync/scripts/prod/10-dump-schema.sh —— schema-only plain dump + 指纹 + manifest（phase=schema）。
# 起手校验 EXPECT_SYSID 非空，拒跑指向先跑 00-inventory；正文见 tasks.md 2.1。
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib.sh"
# shellcheck disable=SC1091
source "${HERE}/pg-sync-prod.env"

: "${SRC_DB:?pg-sync-prod.env 里 SRC_DB 必填}"
: "${DUMP_DIR:?pg-sync-prod.env 里 DUMP_DIR 必填}"
LOCK_WAIT_TIMEOUT="${LOCK_WAIT_TIMEOUT:-30s}"
NICE="${NICE:-19}"
IONICE="${IONICE:--c3}"

# ---- 身份核对：EXPECT_SYSID 为空只有 00-inventory 豁免，本脚本 MUST 拒跑 --------------------
[[ -n "${EXPECT_SYSID:-}" ]] || die \
    "EXPECT_SYSID 为空" \
    "10-dump-schema 要求先核对过身份，只有 00-inventory 在此项为空时豁免" \
    "先跑 00-inventory.sh，把打印出的 system_identifier 填进 pg-sync-prod.env 的 EXPECT_SYSID"

probe_conn "${SRC_DB}"

ACTUAL_SYSID="$(psql_ro "${SRC_DB}" -c 'select system_identifier from pg_control_system()')"
[[ "${ACTUAL_SYSID}" == "${EXPECT_SYSID}" ]] || die \
    "身份不符：EXPECT_SYSID=${EXPECT_SYSID}，实际 system_identifier=${ACTUAL_SYSID}" \
    "bundle 复制到了错误的生产机，或连的库不是预期的库" \
    "确认复制到了正确的生产机，或重跑 00-inventory.sh 重新核对并更新 EXPECT_SYSID"

if [[ -n "${EXPECT_HOSTNAME:-}" ]]; then
    ACTUAL_HOSTNAME="$(hostname)"
    # 不把实际主机名打到 stdout（T58 P3/P4）：只说不符，不回显值
    [[ "${ACTUAL_HOSTNAME}" == "${EXPECT_HOSTNAME}" ]] || die \
        "身份不符：hostname 与 EXPECT_HOSTNAME 不一致" \
        "bundle 可能被复制到了错误的机器" \
        "确认这是预期的生产机，或修正 pg-sync-prod.env 的 EXPECT_HOSTNAME"
fi

# ---- schema 阶段锁槽账：全部用户表 × 1.2 ≤ 可用锁槽，否则拒跑（E8 收紧）--------------------
TABLE_COUNT="$(psql_ro "${SRC_DB}" -c "
    select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r','p')
      and n.nspname not in ('pg_catalog','information_schema')
      and n.nspname !~ '^pg_toast'")"
MAX_LOCKS="$(psql_ro "${SRC_DB}" -c 'show max_locks_per_transaction')"
MAX_CONN="$(psql_ro "${SRC_DB}" -c 'show max_connections')"
MAX_PREP="$(psql_ro "${SRC_DB}" -c 'show max_prepared_transactions')"
CUR_LOCKS="$(psql_ro "${SRC_DB}" -c 'select count(*) from pg_locks')"
LOCK_SLOTS=$(( MAX_LOCKS * (MAX_CONN + MAX_PREP) - CUR_LOCKS ))
LOCK_NEEDED=$(( (TABLE_COUNT * 12 + 9) / 10 ))   # 向上取整的 ×1.2
if (( LOCK_NEEDED > LOCK_SLOTS )); then
    die \
        "锁槽预算不足（RED lock-budget）：全部用户表 ${TABLE_COUNT} 张 × 1.2 ≈ ${LOCK_NEEDED} > 可用锁槽 ${LOCK_SLOTS}" \
        "schema 阶段 pg_dump 会对每张用户表取 ACCESS SHARE 锁" \
        "升级窗口把 max_locks_per_transaction 调大后重启 PostgreSQL，再重跑本脚本"
fi
ok "锁槽账：全部用户表 ${TABLE_COUNT} 张 × 1.2 ≈ ${LOCK_NEEDED} ≤ 可用锁槽 ${LOCK_SLOTS}"

# ---- pg_dump 客户端二进制 ------------------------------------------------------------
if [[ -n "${PG_BIN:-}" ]]; then
    PG_DUMP="${PG_BIN%/}/pg_dump"
    [[ -x "${PG_DUMP}" ]] || die \
        "PG_BIN 指向的目录下没有可执行的 pg_dump（${PG_DUMP}）" \
        "PG_BIN 填错" \
        "改 pg-sync-prod.env 的 PG_BIN，或留空使用 PATH 里的默认版本"
else
    PG_DUMP="$(require_cmd pg_dump)"
fi

# ---- 落点 + 清理 trap + 日志 ----------------------------------------------------------
SYNC_ID="$(new_sync_id "${SRC_DB}")"
OUT_DIR="${DUMP_DIR%/}/${SYNC_ID}"
mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"
chown postgres:postgres "${OUT_DIR}"  # [impl-review-fix] F1：pg_dump 以 sudo -u postgres 跑，须能写入 OUT_DIR
trap_cleanup "${OUT_DIR}"
log_tee "${OUT_DIR}/log.txt"

info "sync_id=${SYNC_ID}　phase=schema　落点=${OUT_DIR}"

snapshot_activity() {
    info "pg_stat_activity 快照（$1，只统计 state/wait_event 计数，不含 query 文本）"
    psql_ro "${SRC_DB}" -c "
        select state, coalesce(wait_event,'-') as wait_event, count(*)
        from pg_stat_activity group by 1,2 order by 1,2"
}
snapshot_activity "dump 前"

STARTED_AT="$(date -Iseconds)"
LSN_START="$(psql_ro "${SRC_DB}" -c 'select pg_current_wal_lsn()')"

# ---- extensions 清单（含 extversion）---------------------------------------------------
EXT_ROWS="$(psql_ro "${SRC_DB}" -c "select extname, extversion from pg_extension order by extname")"
EXTENSIONS_JSON="[]"
if [[ -n "${EXT_ROWS}" ]]; then
    EXTENSIONS_JSON="["
    _first=1
    while IFS='|' read -r _name _ver; do
        [[ -n "${_name}" ]] || continue
        [[ "${_first}" -eq 1 ]] && _first=0 || EXTENSIONS_JSON+=","
        EXTENSIONS_JSON+="{\"name\":\"${_name}\",\"version\":\"${_ver}\"}"
    done <<< "${EXT_ROWS}"
    EXTENSIONS_JSON+="]"
fi

# ---- schema-only plain dump（指纹算法：Global Constraints / design.md Decisions）------------
info "pg_dump schema-only（nice ${NICE} / ionice ${IONICE}）"
sudo -u postgres nice -n "${NICE}" ionice ${IONICE} "${PG_DUMP}" \
    -d "${SRC_DB}" \
    -Fp --schema-only --no-owner --no-privileges --no-tablespaces --quote-all-identifiers \
    --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" \
    -f "${OUT_DIR}/schema.sql" \
    || die \
        "pg_dump schema-only 失败" \
        "常见原因：某表被 ACCESS EXCLUSIVE 持有超过 LOCK_WAIT_TIMEOUT（${LOCK_WAIT_TIMEOUT}），或磁盘写满" \
        "错峰重跑，或看上面 pg_dump 的报错信息"
chmod 600 "${OUT_DIR}/schema.sql"

LSN_END="$(psql_ro "${SRC_DB}" -c 'select pg_current_wal_lsn()')"
FINISHED_AT="$(date -Iseconds)"
snapshot_activity "dump 后"

# MUST NOT 传固定 --restrict-key：保留 pg_dump 生成的随机 \restrict / \unrestrict 行在 schema.sql 里
# （psql 元命令注入防护），指纹只在算法这一步的管道内去掉这两类行，不改动落盘的 schema.sql 本身。
SCHEMA_SHA256="$(grep -vE '^-- Dumped|^\\restrict |^\\unrestrict ' "${OUT_DIR}/schema.sql" | sha256sum | awk '{print $1}')"
FILE_SHA256="$(sha256sum "${OUT_DIR}/schema.sql" | awk '{print $1}')"
FILE_BYTES="$(wc -c < "${OUT_DIR}/schema.sql" | tr -d ' ')"

PG_VERSION="$(psql_ro "${SRC_DB}" -c 'show server_version')"
PG_DUMP_VERSION="$("${PG_DUMP}" --version | awk '{print $NF}')"

cat > "${OUT_DIR}/manifest.json" <<JSON
{
  "sync_id": "${SYNC_ID}",
  "phase": "schema",
  "source": {
    "sysid": "${ACTUAL_SYSID}",
    "db": "${SRC_DB}",
    "pg_version": "${PG_VERSION}",
    "started_at": "${STARTED_AT}",
    "finished_at": "${FINISHED_AT}",
    "lsn_start": "${LSN_START}",
    "lsn_end": "${LSN_END}"
  },
  "schema_sha256": "${SCHEMA_SHA256}",
  "extensions": ${EXTENSIONS_JSON},
  "files": [
    {"path": "schema.sql", "sha256": "${FILE_SHA256}", "bytes": ${FILE_BYTES}}
  ],
  "tools": {"pg_dump": "${PG_DUMP_VERSION}", "compress": "none"}
}
JSON
chmod 600 "${OUT_DIR}/manifest.json"

ok "schema dump 完成：sync_id=${SYNC_ID}　schema_sha256=${SCHEMA_SHA256}"
info "下一步：把 ${OUT_DIR} 传到 dev（30-transport-rsync.sh 或 30-transport-oss.sh）"

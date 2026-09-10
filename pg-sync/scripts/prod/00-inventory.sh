#!/usr/bin/env bash
# pg-sync/scripts/prod/00-inventory.sh —— 只读盘点：解析 DATA_RULES → plan.tsv + 锁槽账 + 磁盘账 + 标红。
# 唯一在 EXPECT_SYSID 为空时也允许跑的脚本（它就是产出该值的地方）。不产生 dump，只写 plan.tsv + log.txt。
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib.sh"
# shellcheck disable=SC1091
source "${HERE}/rules-lib.sh"
# shellcheck disable=SC1091
source "${HERE}/pg-sync-prod.env"

: "${SRC_DB:?pg-sync-prod.env 里 SRC_DB 必填}"
: "${DUMP_DIR:?pg-sync-prod.env 里 DUMP_DIR 必填}"
LOCK_WAIT_TIMEOUT="${LOCK_WAIT_TIMEOUT:-30s}"
WINDOW_SEQSCAN_RED="${WINDOW_SEQSCAN_RED:-1073741824}"   # 缺省 1 GiB，NFR「window 标红阈值」

probe_conn "${SRC_DB}"

ACTUAL_SYSID="$(psql_ro "${SRC_DB}" -c 'select system_identifier from pg_control_system()')"
if [[ -n "${EXPECT_SYSID:-}" ]]; then
    [[ "${ACTUAL_SYSID}" == "${EXPECT_SYSID}" ]] || die \
        "身份不符：EXPECT_SYSID=${EXPECT_SYSID}，实际 system_identifier=${ACTUAL_SYSID}" \
        "bundle 复制到了错误的生产机，或连的库不是预期的库" \
        "确认复制到了正确的生产机，或改正 pg-sync-prod.env 的 EXPECT_SYSID"
else
    info "EXPECT_SYSID 为空（首跑）：这台机的 system_identifier = ${ACTUAL_SYSID}"
    info "把它填进 pg-sync-prod.env 的 EXPECT_SYSID，之后 10-dump-schema / 20-dump-data 才会核对身份而不是拒跑"
fi

if [[ -n "${EXPECT_HOSTNAME:-}" ]]; then
    ACTUAL_HOSTNAME="$(hostname)"
    # 不把实际主机名打到 stdout（T58 P3/P4）：只说不符，不回显值
    [[ "${ACTUAL_HOSTNAME}" == "${EXPECT_HOSTNAME}" ]] || die \
        "身份不符：hostname 与 EXPECT_HOSTNAME 不一致" \
        "bundle 可能被复制到了错误的机器" \
        "确认这是预期的生产机，或修正 pg-sync-prod.env 的 EXPECT_HOSTNAME"
fi

# ---- 落点 + 日志（00 自己的 sync_id，只放 plan.tsv + log.txt，不含 dump）--------------------
SYNC_ID="$(new_sync_id "${SRC_DB}")"
OUT_DIR="${DUMP_DIR%/}/${SYNC_ID}"
mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"
trap_cleanup "${OUT_DIR}"
log_tee "${OUT_DIR}/log.txt"

info "sync_id=${SYNC_ID}　phase=inventory　落点=${OUT_DIR}"

# ---- 解析规则、取全量候选表、展开策略（DR-01, DR-03, DR-04, DR-05）--------------------------
info "解析 DATA_RULES"
parse_data_rules
ok "DATA_RULES 共 ${#RULES[@]} 条规则，语法通过"

info "读取全量用户表（relkind=r，排除系统 schema）"
fetch_all_tables
ok "候选表 ${#ALL_TABLES[@]} 张"

info "按规则展开策略（full / none / sample / window）"
classify_tables
ok "计划已生成：$(strategy_count full) full / $(strategy_count window) window / $(strategy_count none) none"

# ---- 锁槽账（data 阶段，信息性：00 只标红不拒跑，拒跑由 20-dump-data 执行）--------------------
compute_lock_budget
LOCK_BUDGET_FLAG="OK"
if (( LOCK_NEEDED > LOCK_SLOTS )); then
    LOCK_BUDGET_FLAG="RED"
    info "锁槽预算：RED lock-budget（待锁 ${LOCK_NEEDED_RAW} 张 × 1.2 ≈ ${LOCK_NEEDED} > 可用锁槽 ${LOCK_SLOTS}）——20-dump-data 到时会拒跑"
else
    ok "锁槽预算：待锁 ${LOCK_NEEDED_RAW} 张 × 1.2 ≈ ${LOCK_NEEDED} ≤ 可用锁槽 ${LOCK_SLOTS}"
fi

# ---- schema 阶段待锁表数（信息性，供 10-dump-schema 参照的同口径数字）------------------------
SCHEMA_TABLE_COUNT="$(count_all_lockable_relkinds)"
SCHEMA_LOCK_NEEDED=$(( (SCHEMA_TABLE_COUNT * 12 + 9) / 10 ))
SCHEMA_LOCK_FLAG="OK"
[[ "${SCHEMA_LOCK_NEEDED}" -gt "${LOCK_SLOTS}" ]] && SCHEMA_LOCK_FLAG="RED"

# ---- 磁盘账（信息性）------------------------------------------------------------------
EST_BYTES="$(est_bytes_total)"
DISK_FREE="$(disk_free_bytes "${DUMP_DIR}")"
DISK_NEEDED=$(( (EST_BYTES * 12 + 9) / 10 ))
DISK_BUDGET_FLAG="OK"
if [[ -n "${DISK_FREE}" ]] && (( DISK_NEEDED > DISK_FREE )); then
    DISK_BUDGET_FLAG="RED"
    info "磁盘预算：RED too-big-for-window（估算 × 1.2 ≈ ${DISK_NEEDED} 字节 > 剩余 ${DISK_FREE} 字节）——20-dump-data 到时会拒跑"
else
    ok "磁盘预算：估算 × 1.2 ≈ ${DISK_NEEDED} 字节 ≤ 剩余 ${DISK_FREE:-<未知>} 字节"
fi

MATVIEWS="$(count_matviews)"
LARGE_OBJECTS="$(count_large_objects)"

# ---- 写 plan.tsv（7 列 + #SUMMARY）-----------------------------------------------------
PLAN_FILE="${OUT_DIR}/plan.tsv"
{
    printf '#schema\ttable\tstrategy\tdetail\test_bytes\tflag\treason\n'
    for row in "${PLAN_ROWS[@]}"; do
        printf '%s\n' "${row}"
    done
    printf '#SUMMARY full=%s window=%s none=%s est_bytes=%s lock_needed=%s lock_slots=%s lock_budget=%s schema_lock_needed=%s schema_lock_budget=%s matviews=%s large_objects=%s disk_free_bytes=%s disk_needed_bytes=%s disk_budget=%s\n' \
        "$(strategy_count full)" "$(strategy_count window)" "$(strategy_count none)" \
        "${EST_BYTES}" "${LOCK_NEEDED}" "${LOCK_SLOTS}" "${LOCK_BUDGET_FLAG}" \
        "${SCHEMA_LOCK_NEEDED}" "${SCHEMA_LOCK_FLAG}" "${MATVIEWS}" "${LARGE_OBJECTS}" \
        "${DISK_FREE:-0}" "${DISK_NEEDED}" "${DISK_BUDGET_FLAG}"
} > "${PLAN_FILE}"
chmod 600 "${PLAN_FILE}"

RED_COUNT="$(grep -cP '\tRED\t' "${PLAN_FILE}" || true)"
[[ "${RED_COUNT}" -gt 0 ]] && info "plan.tsv 里有 ${RED_COUNT} 张表标 RED（多为 no-index-on-<列>），详见 ${PLAN_FILE}"

ok "inventory 完成：sync_id=${SYNC_ID}　plan.tsv=${PLAN_FILE}"
info "下一步：核对 plan.tsv 里的 RED 行；确认无误后跑 10-dump-schema.sh（若还没跑过 schema 阶段）与 20-dump-data.sh"

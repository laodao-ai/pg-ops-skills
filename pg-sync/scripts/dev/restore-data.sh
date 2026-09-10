#!/usr/bin/env bash
# pg-sync/scripts/dev/restore-data.sh —— 守卫（磁盘账/已装载检查）→ 指纹校验 → pg_restore -j --disable-triggers
# + \copy → setval → ANALYZE → 钩子 → 禁连接 + rename 切换 → 报告。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh dev restore-data pg-sync.env build/restore-data.sh → 上 dev 机跑
#   2) 直接版：bash restore-data.sh /path/to/pg-sync.env
set -euo pipefail

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    source "${HERE}/../lib.sh"
    ENV_FILE="${1:?用法: bash $(basename "${BASH_SOURCE[0]}") <pg-sync.env>（或先用 render.sh dev 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    REPORT_TPL_FILE="${HERE}/../../templates/sync-report.md"
    [[ -r "${REPORT_TPL_FILE}" ]] || die "找不到 ${REPORT_TPL_FILE}"
fi

require_root
require_dev_marker

: "${DB_NAME:?pg-sync.env 里 DB_NAME 必填}"
DB_OWNER="${DB_OWNER:-${DB_NAME}}"
[[ "${DB_NAME}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME 只允许小写字母/数字/下划线（当前: ${DB_NAME}）"
[[ "${DB_OWNER}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_OWNER 只允许小写字母/数字/下划线（当前: ${DB_OWNER}）"
SYNC_DB="${DB_NAME}_sync"
PREV_DB="${DB_NAME}_prev"
RESTORE_JOBS="${RESTORE_JOBS:-$(nproc 2>/dev/null || echo 1)}"

T_GUARD_START="$(date +%s)"

# postgres 超级用户写会话（本脚本要建/装/改属主/切数据库，需要写会话；lib.sh 只提供只读的 psql_ro）
psql_su() {
    sudo -u postgres env PGOPTIONS="-c client_min_messages=warning" psql -v ON_ERROR_STOP=1 -qtAX "$@"
}
# 切换用的 rename/DROP 专用会话：lock_timeout=10s（NFR「切换」）
psql_su_lock10() {
    sudo -u postgres env PGOPTIONS="-c client_min_messages=warning -c lock_timeout=10s" psql -v ON_ERROR_STOP=1 -qtAX "$@"
}
qident() { printf '"%s"' "${1//\"/\"\"}"; }

# ---- sync.json 必须存在（F: 未找到 schema 阶段记录）----------------------------------------
SYNC_STATE_DIR="/opt/pg-ops/projects"
SYNC_STATE_FILE="${SYNC_STATE_DIR}/${DB_NAME}.sync.json"
[[ -f "${SYNC_STATE_FILE}" ]] || die \
    "未找到 ${SYNC_STATE_FILE}" \
    "还没跑过 schema 阶段（restore-schema.sh），或已被人手工删除重置" \
    "先跑 restore-schema.sh 完成 schema 阶段"

SYNC_STATE_SCHEMA_SHA256="$(manifest_get "${SYNC_STATE_FILE}" .schema_sha256)"
SYNC_STATE_SCHEMA_SYNC_ID="$(manifest_get "${SYNC_STATE_FILE}" .schema_sync_id)"
SYNC_STATE_SCHEMA_SYNCED_AT="$(manifest_get "${SYNC_STATE_FILE}" .schema_synced_at)"
PREV_DATA_SYNC_ID="$(manifest_get "${SYNC_STATE_FILE}" .data_sync_id)"

# ---- 找 incoming 下最新一次已收到、phase=data 的同步目录 -----------------------------------
: "${RSYNC_DEST_DIR:?pg-sync.env 里 RSYNC_DEST_DIR 未填（receive-setup 用的收件目录，也是本脚本找同步目录的地方）}"
INCOMING_DIR="${RSYNC_DEST_DIR}"
[[ -d "${INCOMING_DIR}" ]] || die \
    "收件目录不存在：${INCOMING_DIR}" \
    "receive-setup 还没跑，或还没收到任何传输" \
    "先在 dev 机跑 receive-setup，再从生产机跑 20-dump-data + 传输"

SYNC_DIR=""
while IFS= read -r d; do
    if [[ -f "${d}manifest.json" ]] && [[ "$(manifest_get "${d}manifest.json" .phase)" == "data" ]]; then
        SYNC_DIR="${d%/}"
        break
    fi
done < <(ls -dt "${INCOMING_DIR%/}"/*/ 2>/dev/null)
[[ -n "${SYNC_DIR}" ]] || die \
    "incoming 下没有带 manifest.json 且 phase=data 的同步目录" \
    "还没收到 data 阶段的传输，或传输未完成" \
    "先在生产机跑 20-dump-data.sh，再跑传输脚本推送"
SYNC_ID="$(basename "${SYNC_DIR}")"
info "sync_id=${SYNC_ID}　phase=data　来源=${SYNC_DIR}"

# ---- sha256 校验（DV-02，F12）-----------------------------------------------------------
verify_manifest_files "${SYNC_DIR}"

# ---- 指纹校验：manifest 的 schema_sha256 必须等于 sync.json 记录（restore-schema 阶段留下的）（F13）----
MANIFEST_SCHEMA_SHA256="$(manifest_get "${SYNC_DIR}/manifest.json" .schema_sha256)"
[[ "${MANIFEST_SCHEMA_SHA256}" == "${SYNC_STATE_SCHEMA_SHA256}" ]] || die \
    "指纹不符：本次 data 基于的 schema（${MANIFEST_SCHEMA_SHA256:0:12}…）≠ sync.json 记录（${SYNC_STATE_SCHEMA_SHA256:0:12}…）" \
    "生产上 schema 在两次 dump 之间发生了变化，或这份 data 属于另一次 schema 同步" \
    "重跑 restore-schema.sh 装载最新 schema，再重跑生产侧 20-dump-data.sh 产出与之匹配的 data"

log_tee "/opt/pg-ops/sync/${SYNC_ID}.log"

# ---- 磁盘账：df(PG 数据目录) ≥ manifest est_bytes × 1.2（F20）------------------------------
EST_BYTES="$(manifest_get "${SYNC_DIR}/manifest.json" .est_bytes)"
PGDATA_DIR="$(psql_ro postgres -c 'show data_directory')"
DISK_FREE="$(df -B1 --output=avail "${PGDATA_DIR}" 2>/dev/null | tail -1 | tr -d ' ')"
DISK_NEEDED=$(( (EST_BYTES * 12 + 9) / 10 ))
if [[ -n "${DISK_FREE}" ]] && (( DISK_NEEDED > DISK_FREE )); then
    die \
        "磁盘不足：估算 × 1.2 ≈ ${DISK_NEEDED} 字节 > 剩余 ${DISK_FREE} 字节" \
        "dev 机数据盘空间不够装载本次同步" \
        "清理 dev 机磁盘空间（如旧的 ${PREV_DB}），或缩小生产侧 DATA_RULES 后重新同步"
fi
ok "磁盘账：估算 × 1.2 ≈ ${DISK_NEEDED} 字节 ≤ 剩余 ${DISK_FREE:-<未知>} 字节"

# ---- 读 plan.tsv（本次 data 的策略清单，随 sync 一起传来，与本次 dump 同源）-------------------
PLAN_FILE="${SYNC_DIR}/plan.tsv"
[[ -r "${PLAN_FILE}" ]] || die "找不到 ${PLAN_FILE}" "20-dump-data.sh 应该会一起产出 plan.tsv" "重跑生产侧传输，确认 plan.tsv 也传了过来"
declare -a FULL_ROWS=() WINDOW_ROWS=()
while IFS=$'\t' read -r p_sch p_tbl p_strat p_detail p_bytes p_flag p_reason; do
    [[ -z "${p_sch}" || "${p_sch}" == \#* ]] && continue
    case "${p_strat}" in
        full) FULL_ROWS+=("${p_sch}"$'\t'"${p_tbl}") ;;
        window) WINDOW_ROWS+=("${p_sch}"$'\t'"${p_tbl}"$'\t'"${p_detail}") ;;
    esac
done < "${PLAN_FILE}"
ok "计划：${#FULL_ROWS[@]} 张 full（pg_restore -Fd）/ ${#WINDOW_ROWS[@]} 张 window（COPY）"

# ---- _sync 计划表均须为空，否则说明已装载过一半，须先重跑 restore-schema 重建空库（F21）--------
NONEMPTY=()
for row in "${FULL_ROWS[@]}" "${WINDOW_ROWS[@]}"; do
    sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"
    # [impl-review-fix] F8：不再吞掉查询错误——2>/dev/null || echo "" 会把查询失败也当成"表为空"，
    # 让 F21 守卫失效。改为让查询错误按 set -e 正常传播，并显式校验返回值只能是 t/f。
    has_rows="$(psql_ro "${SYNC_DB}" -c "select exists(select 1 from $(qident "${sch}").$(qident "${tbl}"))")"
    case "${has_rows}" in
        t) NONEMPTY+=("${sch}.${tbl}") ;;
        f) : ;;
        *) die \
            "检查 ${sch}.${tbl} 是否为空时得到意外结果：${has_rows:-<空>}" \
            "查询本应返回 t/f，出现其它值说明查询本身出了问题" \
            "排查该表是否存在、DB_OWNER 是否有权限读取，修好后重跑本脚本" ;;
    esac
done
if [[ ${#NONEMPTY[@]} -gt 0 ]]; then
    die \
        "${SYNC_DB} 里已有数据的表：${NONEMPTY[*]:0:5}$([[ ${#NONEMPTY[@]} -gt 5 ]] && echo " 等 ${#NONEMPTY[@]} 张")" \
        "上次 restore-data 中断在装载中途，或 DROP ${PREV_DB} 失败后重跑" \
        "先重跑 restore-schema.sh（会重建一份空的 ${SYNC_DB}），再重跑本脚本"
fi
ok "${SYNC_DB} 的计划表均为空，可以装载"

T_GUARD="$(( $(date +%s) - T_GUARD_START ))"

# [impl-review-fix] F1：SYNC_DIR（incoming/）归属发起传输的用户（如 pgsync），postgres 用户
# 未必能读——pg_restore -Fd 直接以文件系统路径访问该目录，须先放开 postgres 的读权限。
chmod -R o+rX "${SYNC_DIR}" 2>/dev/null || true

# ================= pg_restore -Fd（full 清单）（DV-04）====================================
T_RESTORE_START="$(date +%s)"
if [[ ${#FULL_ROWS[@]} -gt 0 ]]; then
    info "pg_restore --data-only --disable-triggers -j ${RESTORE_JOBS}（${#FULL_ROWS[@]} 张表）"
    sudo -u postgres env PGOPTIONS="-c client_min_messages=warning -c maintenance_work_mem=256MB" \
        pg_restore --data-only --disable-triggers -j "${RESTORE_JOBS}" --exit-on-error \
        -d "${SYNC_DB}" "${SYNC_DIR}/data" \
        || die "pg_restore 失败" "见上方报错" "修好后重跑（先重跑 restore-schema.sh 重建空 ${SYNC_DB}）"
    ok "pg_restore 完成"
fi
T_RESTORE="$(( $(date +%s) - T_RESTORE_START ))"

# ================= window 普通表：逐个 copy/*.copy.{zst,gz} 装载（DV-04）====================
T_COPY_START="$(date +%s)"
if [[ ${#WINDOW_ROWS[@]} -gt 0 ]]; then
    for row in "${WINDOW_ROWS[@]}"; do
        sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"
        f=""
        [[ -r "${SYNC_DIR}/copy/${sch}.${tbl}.copy.zst" ]] && f="${SYNC_DIR}/copy/${sch}.${tbl}.copy.zst" DECOMP="zstd -dc"
        [[ -z "${f}" && -r "${SYNC_DIR}/copy/${sch}.${tbl}.copy.gz" ]] && f="${SYNC_DIR}/copy/${sch}.${tbl}.copy.gz" DECOMP="gzip -dc"
        [[ -n "${f}" ]] || die "找不到 ${sch}.${tbl} 的 copy 文件（.copy.zst / .copy.gz 都没有）" \
            "传输可能不完整" "重跑传输步骤"
        info "装载 ${sch}.${tbl}（COPY FROM STDIN，session_replication_role=replica）"
        ${DECOMP} "${f}" | sudo -u postgres env PGOPTIONS="-c client_min_messages=warning" \
            psql -v ON_ERROR_STOP=1 -d "${SYNC_DB}" \
            -c "SET session_replication_role = replica" \
            -c "COPY $(qident "${sch}").$(qident "${tbl}") FROM STDIN" \
            || die "装载 ${sch}.${tbl} 失败" "见上方报错" "修好后重跑（先重跑 restore-schema.sh 重建空 ${SYNC_DB}）"
    done
    ok "window 普通表装载完成（${#WINDOW_ROWS[@]} 张）"
fi
T_COPY="$(( $(date +%s) - T_COPY_START ))"

# ================= setval + ANALYZE（DV-04）================================================
T_ANALYZE_START="$(date +%s)"
SETVAL_COUNT=0
declare -a LOADED_ROWS=() TABLE_ROW_LINES=()
for row in "${FULL_ROWS[@]}"; do LOADED_ROWS+=("${row}"$'\t'"full"); done
for row in "${WINDOW_ROWS[@]}"; do
    sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"
    LOADED_ROWS+=("${sch}"$'\t'"${tbl}"$'\t'"window")
done
for row in "${LOADED_ROWS[@]}"; do
    sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"; strat="$(cut -f3 <<< "${row}")"
    # 找该表所有列，逐列检查是否有 owned sequence
    while IFS= read -r col; do
        [[ -z "${col}" ]] && continue
        seq="$(psql_ro "${SYNC_DB}" -c "select pg_get_serial_sequence('$(qident "${sch}").$(qident "${tbl}")', '${col}')")"
        [[ -z "${seq}" ]] && continue
        psql_su -d "${SYNC_DB}" -c "select setval('${seq}', greatest(coalesce((select max($(qident "${col}")) from $(qident "${sch}").$(qident "${tbl}")), 1), 1))" >/dev/null
        SETVAL_COUNT=$((SETVAL_COUNT + 1))
    done < <(psql_ro "${SYNC_DB}" -c "select column_name from information_schema.columns where table_schema='${sch}' and table_name='${tbl}'")
    psql_su -d "${SYNC_DB}" -c "ANALYZE $(qident "${sch}").$(qident "${tbl}")"
    ROWCOUNT="$(psql_ro "${SYNC_DB}" -c "select count(*) from $(qident "${sch}").$(qident "${tbl}")")"
    TABLE_ROW_LINES+=("| ${sch} | ${tbl} | ${strat} | ${ROWCOUNT} |")
done
ok "setval 完成（${SETVAL_COUNT} 个序列），ANALYZE 完成（${#LOADED_ROWS[@]} 张表）"
T_ANALYZE="$(( $(date +%s) - T_ANALYZE_START ))"

# ================= 钩子：POST_RESTORE_SQL / POST_RESTORE_HOOK（F16）========================
T_HOOKS_START="$(date +%s)"
if [[ -n "${POST_RESTORE_SQL:-}" ]]; then
    [[ -r "${POST_RESTORE_SQL}" ]] || die \
        "POST_RESTORE_SQL 配置了但读不到文件：${POST_RESTORE_SQL}" \
        "该路径相对消费仓根解释；本脚本按当前工作目录解析——若不是在消费仓根（或该文件所在目录）下执行，会找不到" \
        "cd 到含该文件的目录后重跑，或把 POST_RESTORE_SQL 改成从当前工作目录能解析到的路径"
    info "跑 POST_RESTORE_SQL：${POST_RESTORE_SQL}"
    sudo -u postgres env PGOPTIONS="-c client_min_messages=warning" \
        psql -v ON_ERROR_STOP=1 -d "${SYNC_DB}" -c "SET ROLE $(qident "${DB_OWNER}")" -f "${POST_RESTORE_SQL}" \
        || die "POST_RESTORE_SQL 执行失败" "不切换，${SYNC_DB} 保留供排查" "修好 SQL 后重跑（先重跑 restore-schema.sh 重建空 ${SYNC_DB}）"
fi
if [[ -n "${POST_RESTORE_HOOK:-}" ]]; then
    [[ -x "${POST_RESTORE_HOOK}" || -r "${POST_RESTORE_HOOK}" ]] || die \
        "POST_RESTORE_HOOK 配置了但读不到文件：${POST_RESTORE_HOOK}" \
        "同上，按当前工作目录解析" \
        "cd 到含该文件的目录后重跑"
    info "跑 POST_RESTORE_HOOK：${POST_RESTORE_HOOK}（PG_SYNC_DB=${SYNC_DB}）"
    PG_SYNC_DB="${SYNC_DB}" bash "${POST_RESTORE_HOOK}" \
        || die "POST_RESTORE_HOOK 执行失败" "不切换，${SYNC_DB} 保留供排查" "修好脚本后重跑（先重跑 restore-schema.sh 重建空 ${SYNC_DB}）"
fi
T_HOOKS="$(( $(date +%s) - T_HOOKS_START ))"

# ================= 切换：禁连接 → 踢 → DROP _prev → rename ×2 → 恢复连接（DV-05）=============
# 切换区 trap：中断时恢复连接，避免库处于 ALLOW_CONNECTIONS false 的中间状态
switch_cleanup() {
    psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS true" 2>/dev/null || true
    psql_su -d postgres -c "ALTER DATABASE $(qident "${PREV_DB}") ALLOW_CONNECTIONS true" 2>/dev/null || true
    die "切换被中断（SIGINT/SIGTERM），已恢复 ALLOW_CONNECTIONS" \
        "切换区操作未完成" \
        "检查 ${DB_NAME} / ${PREV_DB} / ${SYNC_DB} 状态后重跑"
}
trap switch_cleanup INT TERM
T_SWITCH_START="$(date +%s)"
KICK_COUNT="$(psql_su -d postgres -c "select count(*) from pg_stat_activity where datname in ('${DB_NAME}','${PREV_DB}') and pid <> pg_backend_pid()")"
info "切换前：将踢 ${KICK_COUNT} 个到 ${DB_NAME}/${PREV_DB} 的连接，等 5 秒"
sleep 5

psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS false" 2>/dev/null || true
psql_su -d postgres -c "ALTER DATABASE $(qident "${PREV_DB}") ALLOW_CONNECTIONS false" 2>/dev/null || true
psql_su -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${DB_NAME}','${PREV_DB}') AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true

SWITCHED=0
SWITCH_RESULT="未切换"
ROLLBACK_CMD="# 未切换，${SYNC_DB} 已保留，无需回滚"

if ! psql_su -d postgres -c "SET statement_timeout='30s'; DROP DATABASE IF EXISTS $(qident "${PREV_DB}")"; then
    psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS true" 2>/dev/null || true
    psql_su -d postgres -c "ALTER DATABASE $(qident "${PREV_DB}") ALLOW_CONNECTIONS true" 2>/dev/null || true
    die \
        "DROP DATABASE ${PREV_DB} 失败（F22）" \
        "上一版本库仍有连接或权限问题，未切换" \
        "排查后重跑本脚本（${SYNC_DB} 已装载完成会被 F21 守卫拦住重复装载——先手工 DROP 掉占用 ${PREV_DB} 的连接）"
fi

if psql_su_lock10 -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") RENAME TO $(qident "${PREV_DB}")"; then
    if psql_su_lock10 -d postgres -c "ALTER DATABASE $(qident "${SYNC_DB}") RENAME TO $(qident "${DB_NAME}")"; then
        SWITCHED=1
        psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS true"
        SWITCH_RESULT="已切换：${DB_NAME} 现在是本次同步的数据，旧版本在 ${PREV_DB}"
        ROLLBACK_CMD="$(printf 'ALTER DATABASE "%s" RENAME TO "%s_failed_%s";\nALTER DATABASE "%s" RENAME TO "%s";\nALTER DATABASE "%s" ALLOW_CONNECTIONS true;' \
            "${DB_NAME}" "${DB_NAME}" "$(date +%s)" "${PREV_DB}" "${DB_NAME}" "${DB_NAME}")"
        ok "切换完成：${DB_NAME} ← ${SYNC_DB}，旧版本在 ${PREV_DB}"
    else
        info "第二步 rename（${SYNC_DB} → ${DB_NAME}）失败，自动回滚第一步"
        if psql_su_lock10 -d postgres -c "ALTER DATABASE $(qident "${PREV_DB}") RENAME TO $(qident "${DB_NAME}")"; then
            psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS true" 2>/dev/null || true
            SWITCH_RESULT="未切换（rename 第二步失败，已自动回滚第一步；${DB_NAME} 仍是原来的数据，${SYNC_DB} 保留供排查）"
            # [impl-review-fix] F6：切换失败须以非零码退出，不能落到报告步骤后 exit 0
            die \
                "${SWITCH_RESULT}" \
                "rename ${SYNC_DB} → ${DB_NAME} 失败，常见原因是仍有连接占用或权限问题" \
                "排查占用后重跑本脚本（${SYNC_DB} 已保留，无需重新装载）"
        else
            SWITCH_RESULT="未切换，且回滚失败——需要人工介入：手动把 ${PREV_DB} 改名回 ${DB_NAME} 并 ALLOW_CONNECTIONS true"
            # [impl-review-fix] F6：这是最坏情形（自动回滚也失败），更须非零码退出以触发人工介入
            die \
                "${SWITCH_RESULT}" \
                "两步 rename 均失败：${DB_NAME} 当前处于改名后的中间状态" \
                "手动执行：ALTER DATABASE \"${PREV_DB}\" RENAME TO \"${DB_NAME}\"; ALTER DATABASE \"${DB_NAME}\" ALLOW_CONNECTIONS true;"
        fi
    fi
else
    info "第一步 rename（${DB_NAME} → ${PREV_DB}）失败，未切换"
    psql_su -d postgres -c "ALTER DATABASE $(qident "${DB_NAME}") ALLOW_CONNECTIONS true" 2>/dev/null || true
    SWITCH_RESULT="未切换（rename 第一步失败，${DB_NAME} 未受影响，${SYNC_DB} 保留供排查）"
    # [impl-review-fix] F6：切换失败须以非零码退出，不能落到报告步骤后 exit 0（让调用方误判成功）
    die \
        "${SWITCH_RESULT}" \
        "rename ${DB_NAME} → ${PREV_DB} 失败，常见原因是仍有连接占用或权限问题" \
        "排查占用后重跑本脚本（${SYNC_DB} 已保留，无需重新装载）"
fi
trap - INT TERM
T_SWITCH="$(( $(date +%s) - T_SWITCH_START ))"

# ---- 更新 sync.json（仅切换成功才写 data_* 三项）--------------------------------------------
if [[ "${SWITCHED}" -eq 1 ]]; then
    DATA_SYNCED_AT="$(date -Iseconds)"
    cat > "${SYNC_STATE_FILE}" <<JSON
{
  "schema_sha256": "${SYNC_STATE_SCHEMA_SHA256}",
  "schema_sync_id": "${SYNC_STATE_SCHEMA_SYNC_ID}",
  "schema_synced_at": "${SYNC_STATE_SCHEMA_SYNCED_AT}",
  "target_db": "${DB_NAME}",
  "data_sync_id": "${SYNC_ID}",
  "data_synced_at": "${DATA_SYNCED_AT}",
  "switched_at": "${DATA_SYNCED_AT}"
}
JSON
fi

# ================= 报告 ====================================================================
DISABLED_TRIGGERS_COUNT="${#FULL_ROWS[@]}"
TABLE_ROWS_MD="$(printf '%s\n' "${TABLE_ROW_LINES[@]}")"
SRC_PG_VERSION="$(manifest_get "${SYNC_DIR}/manifest.json" .source.pg_version)"
SRC_DB_NAME="$(manifest_get "${SYNC_DIR}/manifest.json" .source.db)"

REPORT_TMP="$(mktemp)"
if [[ "${PG_OPS_RENDERED:-}" == "1" ]]; then
    echo "${PG_OPS_REPORT_TPL_B64}" | base64 -d > "${REPORT_TMP}"
else
    cp "${REPORT_TPL_FILE}" "${REPORT_TMP}"
fi

export DB_NAME GENERATED_AT="$(date -Iseconds)" SYNC_ID PREV_SYNC_ID="${PREV_DATA_SYNC_ID:-<无>}" \
    SRC_DB="${SRC_DB_NAME:-<未知>}" SRC_PG_VERSION SCHEMA_SHA256="${MANIFEST_SCHEMA_SHA256}" \
    TABLE_ROWS="${TABLE_ROWS_MD}" DISABLED_TRIGGERS_COUNT SETVAL_COUNT \
    T_GUARD T_RESTORE T_COPY T_ANALYZE T_HOOKS T_SWITCH SWITCH_RESULT ROLLBACK_CMD

REPORT_FILE="/opt/pg-ops/projects/${DB_NAME}-sync.md"
mkdir -p "$(dirname "${REPORT_FILE}")"
perl -pe 's/\{\{(\w+)\}\}/exists $ENV{$1} ? $ENV{$1} : ""/ge' "${REPORT_TMP}" > "${REPORT_FILE}"
rm -f "${REPORT_TMP}"
chmod 600 "${REPORT_FILE}"

# 排除模板自身那一行「MUST NOT 含口令…IP」的说明句——它本身就含 IP 这个词，不是泄露
if grep -E 'PASS|AccessKey|IP' "${REPORT_FILE}" | grep -v '自检' >/dev/null 2>&1; then
    die "报告自检失败：${REPORT_FILE} 里出现了 PASS/AccessKey/IP 字样" \
        "报告模板或填充值意外带进了敏感信息" \
        "检查 POST_RESTORE_SQL/HOOK 是否往 stdout 打印了敏感内容，清理后重新生成报告"
fi
ok "报告已生成：${REPORT_FILE}"

ok "restore-data 完成：sync_id=${SYNC_ID}　${SWITCH_RESULT}"

#!/usr/bin/env bash
# pg-sync/scripts/prod/20-dump-data.sh —— 按 plan：-Fd include 清单 dump + COPY 窗口 + manifest（起止双指纹）。
# 起手校验 EXPECT_SYSID 非空，拒跑指向先跑 00-inventory。每次都重新生成一份计划（不读旧 plan.tsv），
# 生成的 plan.tsv 落在本次自己的 sync_id 目录里，与本次实际 dump 出的文件同源、不会有窗口期漂移。
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
NICE="${NICE:-19}"
IONICE="${IONICE:--c3}"
WINDOW_SEQSCAN_RED="${WINDOW_SEQSCAN_RED:-1073741824}"

# ---- 身份核对：EXPECT_SYSID 为空只有 00-inventory 豁免，本脚本 MUST 拒跑 --------------------
[[ -n "${EXPECT_SYSID:-}" ]] || die \
    "EXPECT_SYSID 为空" \
    "20-dump-data 要求先核对过身份，只有 00-inventory 在此项为空时豁免" \
    "先跑 00-inventory.sh，把打印出的 system_identifier 填进 pg-sync-prod.env 的 EXPECT_SYSID"

probe_conn "${SRC_DB}"

ACTUAL_SYSID="$(psql_ro "${SRC_DB}" -c 'select system_identifier from pg_control_system()')"
[[ "${ACTUAL_SYSID}" == "${EXPECT_SYSID}" ]] || die \
    "身份不符：EXPECT_SYSID=${EXPECT_SYSID}，实际 system_identifier=${ACTUAL_SYSID}" \
    "bundle 复制到了错误的生产机，或连的库不是预期的库" \
    "确认复制到了正确的生产机，或重跑 00-inventory.sh 重新核对并更新 EXPECT_SYSID"

if [[ -n "${EXPECT_HOSTNAME:-}" ]]; then
    ACTUAL_HOSTNAME="$(hostname)"
    [[ "${ACTUAL_HOSTNAME}" == "${EXPECT_HOSTNAME}" ]] || die \
        "身份不符：hostname 与 EXPECT_HOSTNAME 不一致" \
        "bundle 可能被复制到了错误的机器" \
        "确认这是预期的生产机，或修正 pg-sync-prod.env 的 EXPECT_HOSTNAME"
fi

# ---- pg_dump / pg_restore 客户端二进制 -------------------------------------------------
if [[ -n "${PG_BIN:-}" ]]; then
    PG_DUMP="${PG_BIN%/}/pg_dump"
    [[ -x "${PG_DUMP}" ]] || die \
        "PG_BIN 指向的目录下没有可执行的 pg_dump（${PG_DUMP}）" "PG_BIN 填错" \
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

info "sync_id=${SYNC_ID}　phase=data　落点=${OUT_DIR}"

# ---- schema 指纹算法（与 10-dump-schema.sh 同一算法，见 design.md Decisions）---------------
compute_schema_fingerprint() {
    sudo -u postgres nice -n "${NICE}" ionice ${IONICE} "${PG_DUMP}" \
        -d "${SRC_DB}" -Fp --schema-only --no-owner --no-privileges --no-tablespaces --quote-all-identifiers \
        --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" \
        | grep -vE '^-- Dumped|^\\restrict |^\\unrestrict ' | sha256sum | awk '{print $1}'
}

# ---- 生成本次计划（DR-01…DR-06）--------------------------------------------------------
info "解析 DATA_RULES 并生成计划"
parse_data_rules
fetch_all_tables
classify_tables
FULL_COUNT="$(strategy_count full)"
WINDOW_COUNT="$(strategy_count window)"
NONE_COUNT="$(strategy_count none)"
ok "计划：${FULL_COUNT} full / ${WINDOW_COUNT} window / ${NONE_COUNT} none"

RED_ROWS=()
for row in "${PLAN_ROWS[@]}"; do
    [[ "$(cut -f6 <<< "${row}")" == RED ]] && RED_ROWS+=("${row}")
done
if [[ ${#RED_ROWS[@]} -gt 0 ]]; then
    info "以下 ${#RED_ROWS[@]} 张表标 RED（多为无索引顺序扫描，只警告不阻断本次 dump）："
    for row in "${RED_ROWS[@]}"; do
        info "  $(cut -f1,2,7 <<< "${row}")"
    done
fi

# ---- 锁槽账 / 磁盘账：不够即拒跑（20-dump-data 与 00-inventory 唯一的不同点）----------------
compute_lock_budget
if (( LOCK_NEEDED > LOCK_SLOTS )); then
    die \
        "锁槽预算不足（RED lock-budget）：待锁 ${LOCK_NEEDED_RAW} 张 × 1.2 ≈ ${LOCK_NEEDED} > 可用锁槽 ${LOCK_SLOTS}" \
        "本次计划里 full/window 两类表数太多" \
        "把部分表在 DATA_RULES 里改成 none 收窄清单，或升级窗口把 max_locks_per_transaction 调大后重启再重跑"
fi
ok "锁槽账：待锁 ${LOCK_NEEDED_RAW} 张 × 1.2 ≈ ${LOCK_NEEDED} ≤ 可用锁槽 ${LOCK_SLOTS}"

EST_BYTES="$(est_bytes_total)"
DISK_FREE="$(disk_free_bytes "${DUMP_DIR}")"
DISK_NEEDED=$(( (EST_BYTES * 12 + 9) / 10 ))
if [[ -n "${DISK_FREE}" ]] && (( DISK_NEEDED > DISK_FREE )); then
    die \
        "磁盘预算不足（too-big-for-window）：估算 × 1.2 ≈ ${DISK_NEEDED} 字节 > 剩余 ${DISK_FREE} 字节" \
        "DUMP_DIR 所在文件系统空间不够本次计划的估算量" \
        "收窄 DATA_RULES（更多 none/更短的 window），或把 DUMP_DIR 指到空间更大的盘后重跑"
fi
ok "磁盘账：估算 × 1.2 ≈ ${DISK_NEEDED} 字节 ≤ 剩余 ${DISK_FREE:-<未知>} 字节"

# ---- 写 plan.tsv（与本次实际 dump 同源）------------------------------------------------
PLAN_FILE="${OUT_DIR}/plan.tsv"
{
    printf '#schema\ttable\tstrategy\tdetail\test_bytes\tflag\treason\n'
    for row in "${PLAN_ROWS[@]}"; do printf '%s\n' "${row}"; done
    printf '#SUMMARY full=%s window=%s none=%s est_bytes=%s lock_needed=%s lock_slots=%s lock_budget=OK disk_free_bytes=%s disk_needed_bytes=%s disk_budget=OK\n' \
        "${FULL_COUNT}" "${WINDOW_COUNT}" "${NONE_COUNT}" "${EST_BYTES}" "${LOCK_NEEDED}" "${LOCK_SLOTS}" "${DISK_FREE:-0}" "${DISK_NEEDED}"
} > "${PLAN_FILE}"
chmod 600 "${PLAN_FILE}"

# ---- 压缩方式探测：pg_dump 内置 --compress（zstd 编译进去了没有），回落 gzip level（F6, F18）---
probe_pgdump_zstd() {
    local tmp out rc
    tmp="$(mktemp -d)"
    chown postgres:postgres "${tmp}"  # [impl-review-fix] F1：探测目录同样需 postgres 可写
    out="$(sudo -u postgres "${PG_DUMP}" -d "${SRC_DB}" --schema-only -Fd --compress=zstd:1 \
        -t '"__pg_sync_zstd_probe__"' -f "${tmp}/probe" 2>&1)" && rc=0 || rc=$?
    rm -rf "${tmp}"
    # [impl-review-fix] F2：先看退出码——成功即支持 zstd；失败且 stderr 提到 zstd 才回落 gzip；
    # 失败但与 zstd 无关（如权限问题）是意外错误，不能悄悄当作"支持 zstd"，须直接报错。
    # 注意：本函数经 $(...) 调用，跑在子 shell 里，子 shell 内 exit/die 不会终止主脚本
    # （bash 对赋值语句里的命令替换失败不触发 set -e）——因此意外错误只回显一个 error: 前缀
    # 的哨兵行，由调用方在主 shell 里判断后再真正 die。
    if [[ ${rc} -eq 0 ]]; then
        echo zstd
    elif [[ "${out}" == *zstd* ]]; then
        echo gzip
    else
        echo "error:${out}"
    fi
}
PGDUMP_COMPRESS_METHOD="$(probe_pgdump_zstd)"
if [[ "${PGDUMP_COMPRESS_METHOD}" == error:* ]]; then
    die \
        "探测 pg_dump 是否支持 zstd 压缩时出现意外错误（非 zstd 相关）" \
        "pg_dump 输出：${PGDUMP_COMPRESS_METHOD#error:}" \
        "排查该错误（如权限/磁盘问题）后重跑本脚本"
fi
if [[ "${PGDUMP_COMPRESS_METHOD}" == zstd ]]; then
    PGDUMP_COMPRESS_ARG="zstd:1"
else
    info "pg_dump 未带 zstd 压缩支持，回落 gzip"
    PGDUMP_COMPRESS_ARG="1"   # 数字 level = 传统 gzip 压缩，各版本 pg_dump 通用
fi

# COPY 窗口路径走独立的 zstd/gzip 客户端命令（require_cmd 缺失自动回落，lib.sh）
COPY_COMPRESS_CMD="$(require_cmd zstd gzip)"
if [[ "${COPY_COMPRESS_CMD}" == zstd ]]; then
    COPY_EXT="copy.zst"
else
    COPY_EXT="copy.gz"
fi

qident() { printf '"%s"' "${1//\"/\"\"}"; }

# ---- pg_stat_activity 快照（dump 前）---------------------------------------------------
snapshot_activity() {
    info "pg_stat_activity 快照（$1，只统计 state/wait_event 计数，不含 query 文本）"
    psql_ro "${SRC_DB}" -c "
        select state, coalesce(wait_event,'-') as wait_event, count(*)
        from pg_stat_activity group by 1,2 order by 1,2"
}
snapshot_activity "dump 前"

STARTED_AT="$(date -Iseconds)"
LSN_START="$(psql_ro "${SRC_DB}" -c 'select pg_current_wal_lsn()')"

info "起手 schema 指纹"
SCHEMA_SHA256_START="$(compute_schema_fingerprint)"

# ---- full 清单：-Fd 一次性 dump（DR-06）------------------------------------------------
if [[ "${FULL_COUNT}" -gt 0 ]]; then
    # 不预先 mkdir：pg_dump -Fd 要求 -f 指向的目录不存在（由它自己创建）
    DUMP_ARGS=(-d "${SRC_DB}" --data-only -Fd -j 1 --compress="${PGDUMP_COMPRESS_ARG}" \
        --lock-wait-timeout="${LOCK_WAIT_TIMEOUT}" -f "${OUT_DIR}/data")
    for row in "${PLAN_ROWS[@]}"; do
        [[ "$(cut -f3 <<< "${row}")" == full ]] || continue
        sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"
        DUMP_ARGS+=(-t "$(qident "${sch}").$(qident "${tbl}")")
    done
    info "pg_dump --data-only -Fd（${FULL_COUNT} 张表，nice ${NICE} / ionice ${IONICE} / compress ${PGDUMP_COMPRESS_ARG}）"
    sudo -u postgres nice -n "${NICE}" ionice ${IONICE} "${PG_DUMP}" "${DUMP_ARGS[@]}" \
        || die \
            "pg_dump --data-only -Fd 失败" \
            "常见原因：某表被 ACCESS EXCLUSIVE 持有超过 LOCK_WAIT_TIMEOUT（${LOCK_WAIT_TIMEOUT}），或磁盘写满" \
            "错峰重跑，或看上面 pg_dump 的报错信息"
    ok "full 清单 dump 完成"
fi

# ---- window 普通表：逐表 COPY（DR-05）---------------------------------------------------
if [[ "${WINDOW_COUNT}" -gt 0 ]]; then
    mkdir -p "${OUT_DIR}/copy"
    for row in "${PLAN_ROWS[@]}"; do
        [[ "$(cut -f3 <<< "${row}")" == window ]] || continue
        sch="$(cut -f1 <<< "${row}")"; tbl="$(cut -f2 <<< "${row}")"; detail="$(cut -f4 <<< "${row}")"
        col="${detail#col=}"; col="${col%%;N=*}"
        n="${detail##*N=}"
        interval="$(n_to_interval "${n}")"
        outfile="${OUT_DIR}/copy/${sch}.${tbl}.${COPY_EXT}"
        info "COPY ${sch}.${tbl} WHERE ${col} >= now() - interval '${interval}'"
        if [[ "${COPY_COMPRESS_CMD}" == zstd ]]; then
            psql_ro "${SRC_DB}" -c "COPY (SELECT * FROM $(qident "${sch}").$(qident "${tbl}") WHERE $(qident "${col}") >= now() - interval '${interval}') TO STDOUT" \
                | zstd -1 -q > "${outfile}" \
                || die "COPY ${sch}.${tbl} 失败" "见上方 psql/zstd 报错" "错峰重跑，或核对该表结构是否与规则匹配"
        else
            psql_ro "${SRC_DB}" -c "COPY (SELECT * FROM $(qident "${sch}").$(qident "${tbl}") WHERE $(qident "${col}") >= now() - interval '${interval}') TO STDOUT" \
                | gzip -1 > "${outfile}" \
                || die "COPY ${sch}.${tbl} 失败" "见上方 psql/gzip 报错" "错峰重跑，或核对该表结构是否与规则匹配"
        fi
    done
    ok "window 普通表 COPY 完成（${WINDOW_COUNT} 张）"
fi

LSN_END="$(psql_ro "${SRC_DB}" -c 'select pg_current_wal_lsn()')"
FINISHED_AT="$(date -Iseconds)"
snapshot_activity "dump 后"

info "结束 schema 指纹（起止双指纹校验）"
SCHEMA_SHA256_END="$(compute_schema_fingerprint)"

if [[ "${SCHEMA_SHA256_START}" != "${SCHEMA_SHA256_END}" ]]; then
    die \
        "schema 指纹起止不一致（起手 ${SCHEMA_SHA256_START:0:12}… / 结束 ${SCHEMA_SHA256_END:0:12}…），不写 manifest" \
        "dump 期间生产库结构发生了 DDL 变更，本次数据可能与目标结构不一致" \
        "确认这段时间是否有人跑了迁移；确认后重跑本脚本（会生成新的 sync_id，本次目录 ${OUT_DIR} 可人工清理）"
fi
ok "schema 指纹起止一致：${SCHEMA_SHA256_START}"

# ---- files[] sha256 + 字节数（data/ 与 copy/ 下的全部文件）------------------------------
FILES_JSON="["
_first=1
while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    rel="${f#"${OUT_DIR}"/}"
    sha="$(sha256sum "${f}" | awk '{print $1}')"
    bytes="$(wc -c < "${f}" | tr -d ' ')"
    [[ "${_first}" -eq 1 ]] && _first=0 || FILES_JSON+=","
    FILES_JSON+="{\"path\":\"${rel}\",\"sha256\":\"${sha}\",\"bytes\":${bytes}}"
done < <(find "${OUT_DIR}/data" "${OUT_DIR}/copy" -type f 2>/dev/null | sort)
FILES_JSON+="]"
chmod -R go-rwx "${OUT_DIR}" 2>/dev/null || true
find "${OUT_DIR}" -type f -exec chmod 600 {} \;
find "${OUT_DIR}" -type d -exec chmod 700 {} \;

PG_VERSION="$(psql_ro "${SRC_DB}" -c 'show server_version')"
PG_DUMP_VERSION="$("${PG_DUMP}" --version | awk '{print $NF}')"

cat > "${OUT_DIR}/manifest.json" <<JSON
{
  "sync_id": "${SYNC_ID}",
  "phase": "data",
  "source": {
    "sysid": "${ACTUAL_SYSID}",
    "db": "${SRC_DB}",
    "pg_version": "${PG_VERSION}",
    "started_at": "${STARTED_AT}",
    "finished_at": "${FINISHED_AT}",
    "lsn_start": "${LSN_START}",
    "lsn_end": "${LSN_END}"
  },
  "schema_sha256": "${SCHEMA_SHA256_START}",
  "plan": "plan.tsv",
  "est_bytes": ${EST_BYTES},
  "files": ${FILES_JSON},
  "tools": {"pg_dump": "${PG_DUMP_VERSION}", "compress": "${COPY_COMPRESS_CMD}:1", "compress_pgdump": "${PGDUMP_COMPRESS_ARG}"}
}
JSON
chmod 600 "${OUT_DIR}/manifest.json"

ok "data dump 完成：sync_id=${SYNC_ID}　schema_sha256=${SCHEMA_SHA256_START}　est_bytes=${EST_BYTES}"
info "下一步：把 ${OUT_DIR} 传到 dev（30-transport-rsync.sh 或 30-transport-oss.sh），再跑 restore-data.sh"

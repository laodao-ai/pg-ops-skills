#!/usr/bin/env bash
# pg-sync/scripts/dev/restore-schema.sh —— 守卫 → 建 <库>_sync → 预建扩展 → SET ROLE 装 schema → 写 sync.json。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh dev restore-schema pg-sync.env build/restore-schema.sh → 上 dev 机跑
#   2) 直接版：bash restore-schema.sh /path/to/pg-sync.env
# 正文见 tasks.md 2.4。
set -euo pipefail

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    source "${HERE}/../lib.sh"
    ENV_FILE="${1:?用法: bash $(basename "${BASH_SOURCE[0]}") <pg-sync.env>（或先用 render.sh dev 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

require_root
require_dev_marker

: "${DB_NAME:?pg-sync.env 里 DB_NAME 必填}"
DB_OWNER="${DB_OWNER:-${DB_NAME}}"
[[ "${DB_NAME}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME 只允许小写字母/数字/下划线（当前: ${DB_NAME}）"
[[ "${DB_OWNER}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_OWNER 只允许小写字母/数字/下划线（当前: ${DB_OWNER}）"
SYNC_DB="${DB_NAME}_sync"

# postgres 超级用户写会话（lib.sh 只提供只读的 psql_ro；本脚本要建库/扩展/装 schema，需要写会话）
psql_su() {
    sudo -u postgres env PGOPTIONS="-c client_min_messages=warning" psql -v ON_ERROR_STOP=1 -qtAX "$@"
}

# ---- 找 incoming 下最新一次已收到、phase=schema 的同步目录 --------------------------------
: "${RSYNC_DEST_DIR:?pg-sync.env 里 RSYNC_DEST_DIR 未填（receive-setup 用的收件目录，也是本脚本找同步目录的地方）}"
INCOMING_DIR="${RSYNC_DEST_DIR}"
[[ -d "${INCOMING_DIR}" ]] || die \
    "收件目录不存在：${INCOMING_DIR}" \
    "receive-setup 还没跑，或还没收到任何传输" \
    "先在 dev 机跑 receive-setup，再从生产机跑 10-dump-schema + 30-transport-rsync"

SYNC_DIR=""
while IFS= read -r d; do
    if [[ -f "${d}manifest.json" ]]; then
        SYNC_DIR="${d%/}"
        break
    fi
done < <(ls -dt "${INCOMING_DIR%/}"/*/ 2>/dev/null)
[[ -n "${SYNC_DIR}" ]] || die \
    "incoming 下没有带 manifest.json 的同步目录" \
    "还没收到任何传输，或传输未完成" \
    "先在生产机跑 10-dump-schema.sh，再跑 30-transport-rsync.sh 推送"
SYNC_ID="$(basename "${SYNC_DIR}")"

PHASE="$(manifest_get "${SYNC_DIR}/manifest.json" .phase)"
[[ "${PHASE}" == "schema" ]] || die \
    "最新收到的同步不是 schema 阶段（phase=${PHASE:-<空>}）" \
    "生产机上次跑的是 20-dump-data 而不是 10-dump-schema，或 incoming 下混了别的同步目录" \
    "确认生产机跑的是 10-dump-schema.sh 再传输，或先清理 incoming 下的其它目录"

log_tee "/opt/pg-ops/sync/${SYNC_ID}.log"
info "sync_id=${SYNC_ID}　phase=schema　来源=${SYNC_DIR}"

# ---- sha256 校验：传输截断/篡改 --------------------------------------------------------
verify_manifest_files "${SYNC_DIR}"

# ---- 同集群校验（默认拒绝把生产错当 dev 覆盖；SYNC_SAME_CLUSTER_OK 开自测口）------------------
SRC_SYSID="$(manifest_get "${SYNC_DIR}/manifest.json" .source.sysid)"
SRC_DB_NAME="$(manifest_get "${SYNC_DIR}/manifest.json" .source.db)"
DEV_SYSID="$(psql_ro postgres -c 'select system_identifier from pg_control_system()')"
if [[ "${SRC_SYSID}" == "${DEV_SYSID}" ]]; then
    [[ "${SYNC_SAME_CLUSTER_OK:-}" == "1" ]] || die \
        "目标与源是同一集群" \
        "system_identifier 相同，且 SYNC_SAME_CLUSTER_OK 未开启——继续下去等于把生产快照装进它自己所在的集群" \
        "确认这不是在往生产写；仅自测场景可在 pg-sync.env 设 SYNC_SAME_CLUSTER_OK=1（且目标库名必须 ≠ 源库名）"
    [[ "${DB_NAME}" != "${SRC_DB_NAME}" ]] || die \
        "目标与源是同一集群且目标库名与源库名相同" \
        "SYNC_SAME_CLUSTER_OK=1 时目标库名必须 ≠ 源库名，否则等于覆盖源库" \
        "改 pg-sync.env 的 DB_NAME 为一个不同的名字（如加 _selftest 后缀）后重跑"
    info "自测开口生效：同集群，但目标库名（${DB_NAME}）≠ 源库名，继续"
fi

# ---- DB_OWNER 与 pg-dev-init 建的库一致（datdba 校验）--------------------------------------
DB_EXISTS="$(psql_ro postgres -c "select 1 from pg_database where datname='${DB_NAME}'")"
[[ "${DB_EXISTS}" == "1" ]] || die \
    "目标库 ${DB_NAME} 不存在" \
    "pg-sync 依赖 pg-dev-init 已经建好这个库与 owner 角色" \
    "先跑 pg-dev-init 建库，再跑本脚本"
DATDBA="$(psql_ro postgres -c "select r.rolname from pg_database d join pg_roles r on r.oid=d.datdba where d.datname='${DB_NAME}'")"
[[ "${DATDBA}" == "${DB_OWNER}" ]] || die \
    "目标库 ${DB_NAME} 的 owner（${DATDBA}）与 DB_OWNER（${DB_OWNER}）不符" \
    "pg-sync.env 的 DB_OWNER 填错，或这不是 pg-dev-init 建的库" \
    "核对 .pg-ops/pg-dev-init.env 的 DB_USER，改 pg-sync.env 的 DB_OWNER 后重跑"

# ---- 重建 <库>_sync（幂等：先踢连接再 DROP，不留半截状态）----------------------------------
info "重建 ${SYNC_DB}"
psql_su -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${SYNC_DB}' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true
psql_su -c "DROP DATABASE IF EXISTS \"${SYNC_DB}\""
psql_su -c "CREATE DATABASE \"${SYNC_DB}\" OWNER \"${DB_OWNER}\" ENCODING 'UTF8' TEMPLATE template0"
ok "${SYNC_DB} 已重建（owner ${DB_OWNER}）"

# ---- 预建扩展（manifest 里的 extensions[]，先于 SET ROLE 装载，避免 owner 角色缺权限建扩展）----
extensions_tsv() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.extensions[]? | [.name, .version] | @tsv' "${file}"
    else
        python3 - "${file}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for e in (data.get('extensions') or []):
    print(f"{e.get('name','')}\t{e.get('version','')}")
PYEOF
    fi
}
while IFS=$'\t' read -r EXT_NAME EXT_VER; do
    [[ -n "${EXT_NAME}" ]] || continue
    if ! psql_su -d "${SYNC_DB}" -c "CREATE EXTENSION IF NOT EXISTS \"${EXT_NAME}\"" >/dev/null 2>&1; then
        die \
            "扩展 ${EXT_NAME} 建立失败" \
            "dev 机大概率未安装该扩展的 so/控制文件" \
            "装上 ${EXT_NAME} 对应的 postgresql-contrib 包（或专用包），确认版本兼容后重跑本脚本（会先重建 ${SYNC_DB}）"
    fi
    DEV_EXT_VER="$(psql_su -d "${SYNC_DB}" -c "select extversion from pg_extension where extname='${EXT_NAME}'")"
    if [[ -n "${EXT_VER}" && -n "${DEV_EXT_VER}" && "${DEV_EXT_VER}" != "${EXT_VER}" ]]; then
        info "扩展 ${EXT_NAME} 版本不同（生产 ${EXT_VER} / dev ${DEV_EXT_VER}），仅警告，不阻断"
    fi
    ok "扩展 ${EXT_NAME}（${DEV_EXT_VER}）已就绪"
done < <(extensions_tsv "${SYNC_DIR}/manifest.json")

# ---- SET ROLE <owner> 装 schema.sql：同一 psql 会话内先 SET ROLE 再执行，创建的对象即归 owner ----
# [impl-review-fix] F1：schema.sql 归属发起同步的用户（如 pgsync），postgres 用户未必能读；
# 改用 cat | psql 经 stdin 灌入，避免依赖 postgres 对该文件的读权限。
info "以 SET ROLE ${DB_OWNER} 装载 schema.sql"
if ! cat "${SYNC_DIR}/schema.sql" | sudo -u postgres env PGOPTIONS="-c client_min_messages=warning" \
        psql -v ON_ERROR_STOP=1 -d "${SYNC_DB}" \
        -c "SET ROLE \"${DB_OWNER}\"" -f -; then
    die \
        "装载 schema.sql 失败" \
        "常见原因：dev 已装扩展版本与 schema 依赖不符，或 DB_OWNER 缺少某些对象所需权限" \
        "看上面 psql 的报错信息，修好后重跑本脚本（会先重建 ${SYNC_DB}，幂等）"
fi
ok "schema 已装载到 ${SYNC_DB}（对象归属 ${DB_OWNER}）"

# ---- 写 /opt/pg-ops/projects/<库>.sync.json（data_* 清空）----------------------------------
SYNC_STATE_DIR="/opt/pg-ops/projects"
mkdir -p "${SYNC_STATE_DIR}"
chmod 700 "${SYNC_STATE_DIR}"
SYNC_STATE_FILE="${SYNC_STATE_DIR}/${DB_NAME}.sync.json"
SCHEMA_SHA256="$(manifest_get "${SYNC_DIR}/manifest.json" .schema_sha256)"
SYNCED_AT="$(date -Iseconds)"
cat > "${SYNC_STATE_FILE}" <<JSON
{
  "schema_sha256": "${SCHEMA_SHA256}",
  "schema_sync_id": "${SYNC_ID}",
  "schema_synced_at": "${SYNCED_AT}",
  "target_db": "${SYNC_DB}",
  "data_sync_id": null,
  "data_synced_at": null,
  "switched_at": null
}
JSON
chmod 600 "${SYNC_STATE_FILE}"
ok "sync.json 已写入 ${SYNC_STATE_FILE}（data_* 已清空）"

ok "restore-schema 完成：${SYNC_DB} 的 schema_sha256=${SCHEMA_SHA256}"
info "下一步：生产机跑 20-dump-data.sh + 传输，再跑 restore-data.sh"

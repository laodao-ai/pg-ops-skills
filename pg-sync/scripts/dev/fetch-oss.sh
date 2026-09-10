#!/usr/bin/env bash
# pg-sync/scripts/dev/fetch-oss.sh —— ossutil cp -r 从 bucket 拉到 incoming/（内网 endpoint）+ sha256 校验。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh dev fetch-oss pg-sync.env build/fetch-oss.sh → 上 dev 机跑
#      sudo bash fetch-oss.sh [sync_id]（缺省 ossutil ls 取最新）
#   2) 直接版：bash fetch-oss.sh <pg-sync.env> [sync_id]
set -euo pipefail

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    source "${HERE}/../lib.sh"
    ENV_FILE="${1:?用法: bash $(basename "${BASH_SOURCE[0]}") <pg-sync.env>（或先用 render.sh dev 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    SYNC_ID_OVERRIDE="${2:-}"
else
    SYNC_ID_OVERRIDE="${1:-}"
fi

require_root
require_dev_marker

: "${OSS_BUCKET:?pg-sync.env 里 OSS_BUCKET 未填}"
: "${OSS_PREFIX:?pg-sync.env 里 OSS_PREFIX 未填}"
: "${OSS_ENDPOINT_DOWNLOAD:?pg-sync.env 里 OSS_ENDPOINT_DOWNLOAD 未填}"
OSSUTIL_BIN="$(require_cmd ossutil)"

# ---- incoming/ 目录：与 rsync 路线共用同一个收件点（receive-setup 建的 pgsync 家目录）------
INCOMING_ROOT="${RSYNC_DEST_DIR:-}"
if [[ -z "${INCOMING_ROOT}" ]]; then
    PGSYNC_HOME="$(getent passwd pgsync 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "${PGSYNC_HOME}" ]] || die \
        "算不出 incoming 目录" \
        "pg-sync.env 里 RSYNC_DEST_DIR 为空，且本机还没有 pgsync 用户" \
        "先跑 receive-setup.sh（哪怕本次走 OSS 路线，也用它建 incoming 目录），或在 pg-sync.env 填 RSYNC_DEST_DIR"
    INCOMING_ROOT="${PGSYNC_HOME}/incoming"
fi

# ---- sync_id：缺省 ossutil ls -s -d 取最新前缀并打印 --------------------------------
SYNC_ID="${SYNC_ID_OVERRIDE}"
if [[ -z "${SYNC_ID}" ]]; then
    SYNC_ID="$("${OSSUTIL_BIN}" ls "oss://${OSS_BUCKET}/${OSS_PREFIX}/" -s -d -e "${OSS_ENDPOINT_DOWNLOAD}" 2>/dev/null \
        | sed -n "s#^oss://${OSS_BUCKET}/${OSS_PREFIX}/\\([^/]\\{1,\\}\\)/\$#\\1#p" \
        | sort | tail -1)"
    [[ -n "${SYNC_ID}" ]] || die \
        "oss://${OSS_BUCKET}/${OSS_PREFIX}/ 下没有可拉的 sync_id" \
        "生产侧还没推送过（30-transport-oss.sh 未跑或未跑完），或 bucket/前缀与生产不一致" \
        "确认生产侧已跑 30-transport-oss.sh 且已成功；核对本机 pg-sync.env 的 OSS_BUCKET/OSS_PREFIX 与生产 pg-sync-prod.env 一致"
fi
info "sync_id：${SYNC_ID}"

# ---- 拉取：--update 只补传未完成 / 有变化的文件 -------------------------------------
SRC="oss://${OSS_BUCKET}/${OSS_PREFIX}/${SYNC_ID}/"
DEST_DIR="${INCOMING_ROOT}/${SYNC_ID}"
mkdir -p "${DEST_DIR}"
info "拉取 ${SRC} -> ${DEST_DIR}/"
"${OSSUTIL_BIN}" cp -r --update -e "${OSS_ENDPOINT_DOWNLOAD}" "${SRC}" "${DEST_DIR}/" || die \
    "从 OSS 拉取失败" \
    "网络波动，或本机只读子账号对该前缀无 GetObject 权限" \
    "确认已 ossutil config 只读子账号、网络能出 443 到 ${OSS_ENDPOINT_DOWNLOAD}，重跑本脚本（--update 续传）"

# ---- sha256 校验 ---------------------------------------------------------------------
verify_manifest_files "${DEST_DIR}"
ok "已拉取并校验：${DEST_DIR}（sync_id=${SYNC_ID}）——下一步：restore-schema.sh 或 restore-data.sh"

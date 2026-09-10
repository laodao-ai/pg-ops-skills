#!/usr/bin/env bash
# pg-sync/scripts/prod/30-transport-oss.sh —— ossutil cp -r 推到 bucket 前缀（外网 endpoint）。
# 用法：bash 30-transport-oss.sh [sync_id]（缺省取 DUMP_DIR 下最新的一份，schema 或 data 阶段皆可）
# 只写 RAM 子账号的 AccessKey 由人在生产机上 `ossutil config` 单独配置——本脚本不读、不打印。
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib.sh"
# shellcheck disable=SC1091
source "${HERE}/pg-sync-prod.env"

: "${DUMP_DIR:?pg-sync-prod.env 里 DUMP_DIR 未填，先在生产机上按注释填好}"
[[ -n "${OSS_BUCKET:-}" && -n "${OSS_PREFIX:-}" && -n "${OSS_ENDPOINT_UPLOAD:-}" ]] || die \
    "pg-sync-prod.env 里 OSS_BUCKET / OSS_PREFIX / OSS_ENDPOINT_UPLOAD 未填全" \
    "本次同步走 rsync 路线，或 OSS 一节没填" \
    "改用 30-transport-rsync.sh；或在 pg-sync-prod.env 补上这三项后重跑本脚本"

OSSUTIL_BIN="$(require_cmd ossutil)"

# ---- 探测：ossutil 已配置 + bucket 前缀可达 -----------------------------------------
STAT_OUT_FILE="$(mktemp)"
trap 'rm -f "${STAT_OUT_FILE}"' EXIT
if ! "${OSSUTIL_BIN}" stat "oss://${OSS_BUCKET}/${OSS_PREFIX}/" -e "${OSS_ENDPOINT_UPLOAD}" >"${STAT_OUT_FILE}" 2>&1; then
    STAT_OUT="$(cat "${STAT_OUT_FILE}")"
    case "${STAT_OUT}" in
        *"NoSuchKey"*)
            # 前缀下还没有任何对象（首次同步的正常态）——bucket 本身可达，继续
            ;;
        *"InvalidAccessKeyId"*|*"AccessDenied"*|*"SignatureDoesNotMatch"*)
            die "连不上 OSS（oss://${OSS_BUCKET}/${OSS_PREFIX}/）" \
                "AccessKey 未配置，或该子账号对这个 bucket/前缀没有权限" \
                "生产机上跑 ossutil config 配好只写 RAM 子账号的 AccessKey；确认该子账号有 PutObject 权限" ;;
        *"NoSuchBucket"*)
            die "连不上 OSS" \
                "bucket ${OSS_BUCKET} 不存在，或 endpoint 与 bucket 所在地域不匹配" \
                "核对 pg-sync-prod.env 里的 OSS_BUCKET 与 OSS_ENDPOINT_UPLOAD" ;;
        *)
            die "连不上 OSS（oss://${OSS_BUCKET}/${OSS_PREFIX}/）" \
                "${STAT_OUT}" \
                "确认 ossutil 已装（命令已找到）、已跑 ossutil config、网络能出 443 到 ${OSS_ENDPOINT_UPLOAD}" ;;
    esac
fi
rm -f "${STAT_OUT_FILE}"
trap - EXIT
ok "OSS bucket 前缀可达：oss://${OSS_BUCKET}/${OSS_PREFIX}/"

# ---- sync_id：缺省取 DUMP_DIR 下最新（按目录名排序，sync_id = <db>-YYYYmmdd-HHMMSS 天然可排序）----
SYNC_ID="${1:-}"
if [[ -z "${SYNC_ID}" ]]; then
    SYNC_ID="$(find "${DUMP_DIR}" -mindepth 1 -maxdepth 1 -type d ! -name keys -printf '%f\n' 2>/dev/null | sort | tail -1)"
    [[ -n "${SYNC_ID}" ]] || die \
        "DUMP_DIR（${DUMP_DIR}）下没有可传的 sync_id 目录" \
        "还没跑过 10-dump-schema.sh 或 20-dump-data.sh" \
        "先跑 10-dump-schema.sh（schema 阶段）或 20-dump-data.sh（data 阶段），再跑本脚本"
    info "sync_id 缺省取最新：${SYNC_ID}"
fi
SRC_DIR="${DUMP_DIR}/${SYNC_ID}"
[[ -d "${SRC_DIR}" ]] || die \
    "找不到 ${SRC_DIR}" \
    "给定的 sync_id 不存在" \
    "确认 sync_id 拼写，或不传参数取默认最新"

# ---- 推送：--update 只补传未完成 / 有变化的文件，失败重试 3 次 ----------------------
DEST="oss://${OSS_BUCKET}/${OSS_PREFIX}/${SYNC_ID}/"
info "推送 ${SRC_DIR}/ -> ${DEST}"
ATTEMPT=1
while true; do
    if "${OSSUTIL_BIN}" cp -r --update -e "${OSS_ENDPOINT_UPLOAD}" "${SRC_DIR}/" "${DEST}"; then
        break
    fi
    if [[ "${ATTEMPT}" -ge 3 ]]; then
        die \
            "推送 OSS 失败（已重试 3 次）" \
            "网络波动或权限问题，见上方 ossutil 输出" \
            "确认网络与 AccessKey 权限后重跑本脚本（--update 只补传未完成的文件，无需从头重传）"
    fi
    ATTEMPT=$((ATTEMPT + 1))
    echo "[*] 推送失败，${ATTEMPT}/3 次重试..." >&2
    sleep 3
done
ok "已推送到 ${DEST}（sync_id=${SYNC_ID}）——下一步：dev 机上跑 fetch-oss.sh 拉取"

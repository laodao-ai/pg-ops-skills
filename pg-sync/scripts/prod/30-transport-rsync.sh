#!/usr/bin/env bash
# pg-sync/scripts/prod/30-transport-rsync.sh —— 首跑生成 ed25519 并打印公钥；之后 rsync 推到 dev incoming/。
# 正文见 tasks.md 2.2。
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${HERE}/lib.sh"
# shellcheck disable=SC1091
source "${HERE}/pg-sync-prod.env"

: "${DUMP_DIR:?pg-sync-prod.env 里 DUMP_DIR 必填}"
RSYNC_DEST_USER="${RSYNC_DEST_USER:-pgsync}"

KEY_DIR="${DUMP_DIR%/}/keys"
KEY_FILE="${KEY_DIR}/id_ed25519"
mkdir -p "${KEY_DIR}"
chmod 700 "${KEY_DIR}"

# ---- 首跑：生成 ed25519、打印公钥、退出 0（不做传输）--------------------------------------
if [[ ! -f "${KEY_FILE}" ]]; then
    require_cmd ssh-keygen >/dev/null
    ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "pg-sync-prod" >/dev/null
    chmod 600 "${KEY_FILE}"
    chmod 644 "${KEY_FILE}.pub"
    ok "首跑：传输密钥已生成"
    echo
    echo "把下面这行公钥贴进开发机 .pg-ops/pg-sync.env 的 RSYNC_SRC_PUBKEY，再用 render.sh dev receive-setup"
    echo "渲染并上传 dev 机执行一次 receive-setup（一次性），然后重跑本脚本推送："
    echo
    cat "${KEY_FILE}.pub"
    echo
    exit 0
fi

# ---- 找最新一次待传输的同步目录（有 manifest.json 即视为已产出，按 mtime 取最新）------------
SYNC_DIR=""
while IFS= read -r d; do
    if [[ -f "${d}manifest.json" ]]; then
        SYNC_DIR="${d%/}"
        break
    fi
done < <(ls -dt "${DUMP_DIR%/}"/*/ 2>/dev/null | grep -v '/keys/$')
[[ -n "${SYNC_DIR}" ]] || die \
    "找不到待传输的同步目录" \
    "${DUMP_DIR} 下没有带 manifest.json 的同步目录" \
    "先跑 10-dump-schema.sh 或 20-dump-data.sh 产出一份 dump"
SYNC_ID="$(basename "${SYNC_DIR}")"

[[ -n "${RSYNC_DEST_HOST:-}" ]] || die \
    "RSYNC_DEST_HOST 为空" \
    "pg-sync-prod.env 没填 dev 主机地址" \
    "在开发机 pg-sync.env 填好 RSYNC_DEST_HOST 后重渲染 bundle 上传"
[[ -n "${RSYNC_DEST_DIR:-}" ]] || die \
    "RSYNC_DEST_DIR 为空" \
    "pg-sync-prod.env 没填 dev 收件目录" \
    "在开发机 pg-sync.env 填好 RSYNC_DEST_DIR 后重渲染 bundle 上传"
[[ -n "${RSYNC_DEST_HOSTKEY:-}" ]] || die \
    "RSYNC_DEST_HOSTKEY 为空" \
    "dev 机跑 receive-setup 后会在结尾打印 ssh-keyscan -t ed25519 一行，还没贴进 pg-sync-prod.env" \
    "先在 dev 机跑 receive-setup，把打印的一行贴进开发机 pg-sync.env 的 RSYNC_DEST_HOSTKEY，重渲染 bundle 上传"

require_cmd rsync >/dev/null
require_cmd ssh >/dev/null

KNOWN_HOSTS="${KEY_DIR}/known_hosts"
printf '%s\n' "${RSYNC_DEST_HOSTKEY}" > "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"

# 不把 RSYNC_DEST_HOST / RSYNC_DEST_DIR（主机名/IP/路径）打到 stdout（T58 P3/P4）
SSH_OPTS=(-i "${KEY_FILE}" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${KNOWN_HOSTS}" -o ConnectTimeout=15 -o BatchMode=yes)
DEST="${RSYNC_DEST_USER}@${RSYNC_DEST_HOST}:${RSYNC_DEST_DIR%/}/${SYNC_ID}/"

info "推送 sync_id=${SYNC_ID} 到 dev incoming/"
if ! rsync -a --partial --timeout=300 -e "ssh ${SSH_OPTS[*]}" "${SYNC_DIR}/" "${DEST}" 2>"${KEY_DIR}/.last-rsync-err"; then
    die \
        "推送到 dev incoming 失败（--partial 已保留已传部分，重跑本脚本可续传）" \
        "三种可能之一：dev 还没跑 receive-setup / RSYNC_SRC_PUBKEY 与这把私钥不配对 / ufw 未放行本机出口 IP（详见 ${KEY_DIR}/.last-rsync-err）" \
        "对照 receive-setup 的执行结果逐项核对：pgsync 用户与 authorized_keys、RSYNC_SRC_IP 放行、RSYNC_DEST_HOSTKEY 是否与 dev 当前公钥一致"
fi
rm -f "${KEY_DIR}/.last-rsync-err"
ok "已推送到 dev（sync_id=${SYNC_ID}）"

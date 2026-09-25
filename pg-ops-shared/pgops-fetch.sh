#!/usr/bin/env bash
# pgops-fetch.sh —— 把服务器 /opt/pg-ops/ 下的一个文件（可能含口令）取回到本地 .pg-ops/ 之下。
# 用法：pgops-fetch.sh <host> <远端路径>
#
# 本地落点由远端路径推导，调用方无从指定：
#   /opt/pg-ops/projects/myproj.md  ->  .pg-ops/projects/myproj.md
#   /opt/pg-ops/handover.md         ->  .pg-ops/handover.md
# 本地布局镜像服务器布局，于是「远端文件 ↔ 本地副本」一一对应：一库一份、
# 永不互相覆盖。曾经的第三参数由调用方自由指定，两个远端文档可以静默落到
# 同一个本地名上——安全没破（落点仍在 .pg-ops/ 内），但人打开文件看到的是
# 另一个库的内容，会以为供给没跑完（T73）。
set -euo pipefail
umask 077

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/pgops-lib.sh"

HOST="${1:?用法: pgops-fetch.sh <host> <远端路径>}"
REMOTE="${2:?用法: pgops-fetch.sh <host> <远端路径>}"
# 旧的三参数调用必须 fail-loud：静默忽略第三参数会让调用方以为文件落在他
# 指定的位置，而实际落点已改为推导得来（T73）——行为变了却不报错最伤人。
[[ $# -le 2 ]] || die "参数过多（收到 $# 个）：<本地文件> 参数已移除" \
    "落点改由远端路径推导（T73），调用方不再指定本地文件名" \
    "去掉第三个参数：pgops-fetch.sh ${HOST} ${REMOTE}"

[[ "${HOST}" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "host 格式非法: ${HOST}"
[[ "${HOST}" != -* ]] || die "host 不能以 - 开头: ${HOST}"
[[ "${REMOTE}" == /opt/pg-ops/* ]] || die "远端路径必须以 /opt/pg-ops/ 开头: ${REMOTE}"
[[ "${REMOTE}" =~ ^[A-Za-z0-9_./-]+$ ]] || die "远端路径含非法字符: ${REMOTE}"
[[ "${REMOTE}" != *..* ]] || die "远端路径不允许含 ..: ${REMOTE}" "路径遍历会绕过 /opt/pg-ops/ 前缀" "去掉 .. 段"

REMOTE_REL="${REMOTE#/opt/pg-ops/}"
[[ -n "${REMOTE_REL}" ]] || die "远端路径不能是 /opt/pg-ops/ 目录本身: ${REMOTE}" \
    "取的是文件，不是目录" "给出 /opt/pg-ops/ 下的具体文件路径"
LOCAL=".pg-ops/${REMOTE_REL}"

# 推导出的路径必然在 .pg-ops/ 之下，但 .pg-ops/ 或其子目录可能是指向仓外的
# 软链——下面的 realpath 前缀比对挡的是这一种，推导本身挡不住。
LOCAL_DIR="$(dirname "${LOCAL}")"
mkdir -p "${LOCAL_DIR}"
LOCAL_DIR_REAL="$(cd "${LOCAL_DIR}" && pwd -P)"

if [[ -e "$(pwd -P)/.pg-ops" ]]; then
    PGOPS_REAL="$(cd "$(pwd -P)/.pg-ops" && pwd -P)"
else
    PGOPS_REAL="$(pwd -P)/.pg-ops"
fi

case "${LOCAL_DIR_REAL}/" in
    "${PGOPS_REAL}/"|"${PGOPS_REAL}"/*) : ;;
    *)
        die "拒绝写到 ${LOCAL}" \
            "含口令文档只允许落在 deny 覆盖的 .pg-ops/ 之下" \
            "目标改为 .pg-ops/<文件>"
        ;;
esac

TMP="$(mktemp "${LOCAL_DIR_REAL}/.pgops-fetch.XXXXXX")"
cleanup() { rm -f "${TMP}"; }
trap cleanup EXIT

rc=0
timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 -- "${HOST}" sudo cat -- "${REMOTE}" > "${TMP}" || rc=$?

if [[ "${rc}" -ne 0 || ! -s "${TMP}" ]]; then
    die "取回 ${REMOTE} 失败（rc=${rc}）" \
        "连不上 / 无 sudo / 文件不存在 / 60s 超时" \
        "手工 ssh ${HOST} sudo ls /opt/pg-ops/ 核路径与权限后重试"
fi

mv "${TMP}" "${LOCAL}"
trap - EXIT
echo "已写入 ${LOCAL}"

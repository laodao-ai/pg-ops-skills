#!/usr/bin/env bash
# pg-sync/scripts/dev/receive-setup.sh —— 一次性：pgsync 用户 + rrsync -wo 受限 key + incoming/ + ufw 放行。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh dev receive-setup pg-sync.env build/receive-setup.sh → 上 dev 机 sudo bash
#   2) 直接版：sudo bash receive-setup.sh /path/to/pg-sync.env
# 正文见 tasks.md 2.3。
set -euo pipefail

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck disable=SC1091
    source "${HERE}/../lib.sh"
    ENV_FILE="${1:?用法: sudo bash $(basename "${BASH_SOURCE[0]}") <pg-sync.env>（或先用 render.sh dev 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

require_root
require_dev_marker

RSYNC_DEST_USER="${RSYNC_DEST_USER:-pgsync}"
[[ "${RSYNC_DEST_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "RSYNC_DEST_USER 只允许小写字母/数字/下划线/连字符（当前: ${RSYNC_DEST_USER}）"

# ---- RSYNC_DEST_DIR：留空按 handover.md 记录的 PostgreSQL 数据目录推出 <DATA_ROOT>/pg-ops/sync/incoming ----
if [[ -z "${RSYNC_DEST_DIR:-}" ]]; then
    _data_root="/var/lib"
    if [[ -r /opt/pg-ops/handover.md ]]; then
        _guess="$(sed -n 's#.*数据目录 `\([^`]*\)/postgresql/[^`]*`.*#\1#p' /opt/pg-ops/handover.md | head -1)"
        [[ -n "${_guess}" ]] && _data_root="${_guess}"
    fi
    RSYNC_DEST_DIR="${_data_root%/}/pg-ops/sync/incoming"
    info "RSYNC_DEST_DIR 为空，按 handover.md 推出：（已写入本次执行，未回填 env）"
fi

# ---- rrsync：Ubuntu 的 rsync 包把它当脚本/压缩脚本发行，不一定在 PATH 上 --------------------
RRSYNC_BIN=""
for c in /usr/bin/rrsync /usr/share/rsync/scripts/rrsync /usr/lib/rsync/rrsync; do
    if [[ -x "${c}" ]]; then RRSYNC_BIN="${c}"; break; fi
done
if [[ -z "${RRSYNC_BIN}" ]]; then
    for gz in /usr/share/rsync/scripts/rrsync.gz /usr/share/doc/rsync/scripts/rrsync.gz; do
        if [[ -r "${gz}" ]]; then
            gunzip -k -c "${gz}" > /usr/local/bin/rrsync
            chmod 755 /usr/local/bin/rrsync
            RRSYNC_BIN="/usr/local/bin/rrsync"
            break
        fi
    done
fi
[[ -n "${RRSYNC_BIN}" ]] || die \
    "找不到 rrsync" \
    "这台机的 rsync 包没带 rrsync 脚本（版本差异）" \
    "确认已装 rsync（apt-get install -y rsync）；仍找不到就从 rsync 源码包的 support/rrsync 手动装到 /usr/local/bin/rrsync 并 chmod 755"
ok "rrsync：${RRSYNC_BIN}"

# ---- 系统用户 pgsync（无 shell 权限以外能力，登录靠 authorized_keys 的强制 command）------------
if id "${RSYNC_DEST_USER}" >/dev/null 2>&1; then
    ok "系统用户 ${RSYNC_DEST_USER} 已存在，跳过创建"
else
    useradd --system --create-home --home-dir "/home/${RSYNC_DEST_USER}" --shell /usr/sbin/nologin "${RSYNC_DEST_USER}"
    ok "系统用户 ${RSYNC_DEST_USER} 已创建"
fi
PGSYNC_HOME="$(getent passwd "${RSYNC_DEST_USER}" | cut -d: -f6)"
[[ -n "${PGSYNC_HOME}" && -d "${PGSYNC_HOME}" ]] || die "用户 ${RSYNC_DEST_USER} 的 home 目录不存在（${PGSYNC_HOME:-<空>}）"

# ---- incoming/ 700，owner = pgsync ----------------------------------------------------
mkdir -p "${RSYNC_DEST_DIR}"
chown "${RSYNC_DEST_USER}:${RSYNC_DEST_USER}" "${RSYNC_DEST_DIR}"
chmod 700 "${RSYNC_DEST_DIR}"
ok "收件目录已就绪（700，owner ${RSYNC_DEST_USER}）"

# ---- authorized_keys 整份重写：restrict,command="rrsync -wo <incoming>" + 公钥 --------------
[[ -n "${RSYNC_SRC_PUBKEY:-}" ]] || die \
    "RSYNC_SRC_PUBKEY 为空" \
    "生产机首跑 30-transport-rsync.sh 会生成 key 并打印公钥，还没贴进 pg-sync.env" \
    "先在生产机跑一次 30-transport-rsync.sh（无 key 时只生成并打印，不传输），把公钥贴进开发机 .pg-ops/pg-sync.env 的 RSYNC_SRC_PUBKEY，重渲染本脚本再跑一次"

SSH_DIR="${PGSYNC_HOME}/.ssh"
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown "${RSYNC_DEST_USER}:${RSYNC_DEST_USER}" "${SSH_DIR}"

AUTH_KEYS="${SSH_DIR}/authorized_keys"
printf 'restrict,command="%s -wo %s" %s\n' "${RRSYNC_BIN}" "${RSYNC_DEST_DIR}" "${RSYNC_SRC_PUBKEY}" > "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
chown "${RSYNC_DEST_USER}:${RSYNC_DEST_USER}" "${AUTH_KEYS}"
ok "authorized_keys 已整份重写（restrict,command=\"${RRSYNC_BIN} -wo\"，只能写 incoming/）"

# ---- ufw：RSYNC_SRC_IP 非空才放行 22（不把该 IP 打到 stdout，T58 P3/P4）-----------------------
if [[ -n "${RSYNC_SRC_IP:-}" ]]; then
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qF "${RSYNC_SRC_IP}"; then
            ok "ufw 已放行该来源，跳过"
        else
            ufw allow from "${RSYNC_SRC_IP}" to any port 22 proto tcp comment 'pg-sync prod' >/dev/null
            ok "ufw 已放行生产出口 IP 到 22"
        fi
    else
        info "未装 ufw，跳过放行（若这台机用别的防火墙，需自行放行 22）"
    fi
else
    info "RSYNC_SRC_IP 为空，不动 ufw（22 保持现状）"
fi

echo
ok "receive-setup 完成"
echo
echo "下一步：把下面这行的第一列 localhost 换成生产机将使用的 RSYNC_DEST_HOST 值，整行贴进开发机"
echo ".pg-ops/pg-sync.env 的 RSYNC_DEST_HOSTKEY（生产侧用它写 known_hosts，StrictHostKeyChecking=yes）："
echo
ssh-keyscan -t ed25519 localhost 2>/dev/null | grep '^localhost ' || info "ssh-keyscan 未取到（sshd 是否在跑？可手动执行: ssh-keyscan -t ed25519 localhost）"

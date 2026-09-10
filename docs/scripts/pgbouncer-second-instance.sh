#!/usr/bin/env bash
# pgbouncer-second-instance.sh —— 在已有单实例 PgBouncer 的机器上，再起一个第二实例（另一个端口、另一种池模式）
#
# 做法照 pg-dev-server：复制现有 pgbouncer.ini 改端口 / 池模式 / 日志 / pid，复制发行版的 pgbouncer.service 改 ini 路径。
# 不装新包，一个 pgbouncer 二进制跑两个进程。
#
# 典型用法：既有 6432 是 session，再起 7432 **transaction**——只有 transaction 模式才真正省后端
# （空闲的客户端连接不再各占一个后端）。服务逐个证明兼容 transaction 后切到 7432，不兼容的留 6432。
#
# 幂等：目标 ini 已存在 ⇒ 不重生成（两份之后各自维护，不互相抄），只补单元与探活。
#       第三个参数 default_pool_size 每次都会写进目标 ini 并 reload——重跑要带同样的值，或不带第三个参数。
# 对线上零影响：新实例起来时没有任何客户端连它。
# 回滚：systemctl disable --now pgbouncer-<模式>; rm /etc/pgbouncer/pgbouncer-<模式>.ini /etc/systemd/system/pgbouncer-<模式>.service
#
# 用法： sudo bash pgbouncer-second-instance.sh <端口> <pool_mode: transaction|session> [default_pool_size]
#        sudo bash pgbouncer-second-instance.sh 7432 transaction 10
#
# 这不是只读脚本，会写 /etc/pgbouncer 与 /etc/systemd/system 各一个新文件、起一个新服务。不碰现有实例。

set -euo pipefail

PORT="${1:?用法: $0 <端口> <transaction|session> [default_pool_size]}"
MODE="${2:?用法: $0 <端口> <transaction|session> [default_pool_size]}"
POOL_SIZE="${3:-}"
case "${MODE}" in transaction|session) ;; *) echo "pool_mode 只能是 transaction 或 session，收到: ${MODE}" >&2; exit 1;; esac

SRC_INI=/etc/pgbouncer/pgbouncer.ini
UNIT_NAME=pgbouncer-${MODE}
DST_INI=/etc/pgbouncer/${UNIT_NAME}.ini
DST_UNIT=/etc/systemd/system/${UNIT_NAME}.service

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "要 root（写 /etc/pgbouncer 与 systemd 单元）"
[[ -r "${SRC_INI}" ]] || die "找不到 ${SRC_INI}，本脚本只在已有 PgBouncer 的机器上加第二实例"
command -v pgbouncer >/dev/null || die "pgbouncer 二进制不在 PATH"
systemctl cat pgbouncer >/dev/null 2>&1 || die "没有 pgbouncer.service，无法派生第二实例的单元"

SRC_PORT="$(sed -nE 's/^[[:space:]]*listen_port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "${SRC_INI}" | head -1)"
[[ -n "${SRC_PORT}" ]] || die "${SRC_INI} 里没有 listen_port，看不出现有实例的端口"
[[ "${PORT}" != "${SRC_PORT}" ]] || die "端口 ${PORT} 就是现有实例的端口"
SRC_MODE="$(sed -nE 's/^[[:space:]]*pool_mode[[:space:]]*=[[:space:]]*([a-z]+).*/\1/p' "${SRC_INI}" | head -1)"
[[ "${MODE}" != "${SRC_MODE}" ]] || info "注意：现有实例已是 ${SRC_MODE} 模式，第二实例同模式只是多一个端口，省不了后端"

# ---- 1. ini ---------------------------------------------------------------------------------------------
if [[ -e "${DST_INI}" ]]; then
    ok "${DST_INI} 已存在，跳过生成（要重生成先删掉它）"
else
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        die "端口 ${PORT} 已被占用，先 ss -lntp | grep ${PORT} 看是谁"
    fi
    info "从 ${SRC_INI} 派生 ${DST_INI}（端口 ${PORT}，pool_mode=${MODE}）"
    {
        echo "; managed by pg-ops/docs/scripts/pgbouncer-second-instance.sh —— 第二实例，${MODE} 模式，端口 ${PORT}。"
        echo "; 由 $(basename "${SRC_INI}") 于 $(date '+%F %T') 派生，之后两份各自维护，不互相抄。"
        cat "${SRC_INI}"
    } > "${DST_INI}"
    # 端口与池模式强制写死；日志 / pid 若有则改名，避免与第一实例撞同一个文件（pid 撞了第二个进程起不来）
    # GNU sed（目标机是 Ubuntu）；macOS 的 BSD sed 会把 -E 当成 -i 的后缀，本脚本不在 mac 上跑
    sed -E -i \
        -e "s/^([[:space:]]*listen_port[[:space:]]*=[[:space:]]*)[0-9]+/\1${PORT}/" \
        -e "s/^([[:space:]]*pool_mode[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1${MODE}/" \
        -e "s#^([[:space:]]*logfile[[:space:]]*=[[:space:]]*)(.*)/pgbouncer(\.log)?[[:space:]]*\$#\1\2/${UNIT_NAME}.log#" \
        -e "s#^([[:space:]]*pidfile[[:space:]]*=[[:space:]]*)(.*)/pgbouncer(\.pid)?[[:space:]]*\$#\1\2/${UNIT_NAME}.pid#" \
        "${DST_INI}"
    for key in logfile pidfile; do
        a="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)[[:space:]]*\$/\1/p" "${SRC_INI}" | head -1)"
        b="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)[[:space:]]*\$/\1/p" "${DST_INI}" | head -1)"
        if [[ -n "${a}" && "${a}" == "${b}" ]]; then
            rm -f "${DST_INI}"
            die "${key} 改名失败（两份 ini 都是 ${a}），路径形状不是预期的 .../pgbouncer.${key#*file}，手工处理后重跑"
        fi
    done
    grep -qE "^[[:space:]]*pool_mode[[:space:]]*=[[:space:]]*${MODE}" "${DST_INI}" || { rm -f "${DST_INI}"; die "pool_mode 没写成 ${MODE}，${SRC_INI} 里可能没有这一行"; }
    # [databases] 里按库单独写的 pool_size（如 session 实例给 ddl 放宽的 50）是为另一种模式定的，不带进来
    if grep -qE '^[[:space:]]*[a-z_]+[[:space:]]*=.*pool_size=' "${DST_INI}"; then
        sed -E -i '/^[[:space:]]*[a-z_]+[[:space:]]*=.*pool_size=/d' "${DST_INI}"
        ok "已去掉 [databases] 段里按库单独设的 pool_size 行（那是 ${SRC_MODE} 模式的预算）"
    fi
    chown postgres:postgres "${DST_INI}"; chmod 640 "${DST_INI}"
    ok "已生成：$(grep -nE '^[[:space:]]*(listen_addr|listen_port|pool_mode|logfile|pidfile|default_pool_size)[[:space:]]*=' "${DST_INI}" | tr '\n' ' ')"
fi

# ---- 2. 可选：覆盖 default_pool_size（transaction 模式按实测活跃后端数给，pg16 峰期实测 2.3 个 ⇒ 10 足够）------
if [[ -n "${POOL_SIZE}" ]]; then
    if grep -qE '^[[:space:]]*default_pool_size[[:space:]]*=' "${DST_INI}"; then
        sed -E -i "s/^([[:space:]]*default_pool_size[[:space:]]*=[[:space:]]*)[0-9]+/\1${POOL_SIZE}/" "${DST_INI}"
    else
        printf 'default_pool_size = %s\n' "${POOL_SIZE}" >> "${DST_INI}"
    fi
    ok "default_pool_size = ${POOL_SIZE}"
fi

# ---- 3. systemd 单元：从发行版的 pgbouncer.service 派生，只换 ini 路径 / pid / 描述 ---------------------------------
SRC_UNIT="$(systemctl show -p FragmentPath --value pgbouncer)"
[[ -r "${SRC_UNIT}" ]] || die "读不到 pgbouncer.service 的文件：${SRC_UNIT}"
info "从 ${SRC_UNIT} 派生 ${DST_UNIT}"
sed -E \
    -e "s#${SRC_INI//./\\.}#${DST_INI}#g" \
    -e "s#/pgbouncer\.pid#/${UNIT_NAME}.pid#g" \
    -e "s#^Description=.*#Description=connection pooler for PostgreSQL (${MODE} mode, ${PORT}, pg-ops)#" \
    "${SRC_UNIT}" > "${DST_UNIT}.tmp"
grep -q "${DST_INI}" "${DST_UNIT}.tmp" \
    || { rm -f "${DST_UNIT}.tmp"; die "发行版单元的 ExecStart 没有显式写 ${SRC_INI}，无法靠替换派生；systemctl cat pgbouncer 看一下手写"; }
if [[ -e "${DST_UNIT}" ]] && cmp -s "${DST_UNIT}.tmp" "${DST_UNIT}"; then
    rm -f "${DST_UNIT}.tmp"; ok "${DST_UNIT} 已存在且一致，跳过"
else
    mv "${DST_UNIT}.tmp" "${DST_UNIT}"; ok "已写 ${DST_UNIT}"
fi
systemctl daemon-reload

# ---- 4. 起服务 + 探活 ------------------------------------------------------------------------------------
systemctl enable "${UNIT_NAME}" >/dev/null 2>&1 || true
if systemctl is-active --quiet "${UNIT_NAME}"; then
    systemctl reload "${UNIT_NAME}"; ok "${UNIT_NAME} 已在跑，reload 生效"
else
    systemctl start "${UNIT_NAME}"; ok "${UNIT_NAME} 已启动"
fi
sleep 1
systemctl is-active --quiet pgbouncer         || die "第一实例 pgbouncer 不在运行——本脚本不该影响它，立刻 systemctl status pgbouncer"
systemctl is-active --quiet "${UNIT_NAME}"    || die "${UNIT_NAME} 没起来：journalctl -u ${UNIT_NAME} -n 30"
pg_isready -h 127.0.0.1 -p "${PORT}" >/dev/null || die "${PORT} 不接受连接：journalctl -u ${UNIT_NAME} -n 30"
ok "探活：$(pg_isready -h 127.0.0.1 -p "${PORT}")"

echo
echo "两实例："
ss -lntp 2>/dev/null | awk -v a="${SRC_PORT}" -v b="${PORT}" '$4 ~ ":"a"$" || $4 ~ ":"b"$" {print "  " $4 "  " $NF}'
echo
echo "下一步："
echo "  - 管理台：psql -h /var/run/postgresql -p ${PORT} -U postgres pgbouncer -c 'show pools'"
echo "  - 服务逐个切到 ${PORT}（${MODE}）；lib/pq 的服务 DSN 必须带 binary_parameters=yes，否则 transaction 模式报 unnamed prepared statement does not exist"
echo "  - 不兼容的服务留在 ${SRC_PORT}（${SRC_MODE}）；LISTEN/NOTIFY 类永远直连 5432"
echo "  - 回滚本脚本：systemctl disable --now ${UNIT_NAME}; rm ${DST_INI} ${DST_UNIT}; systemctl daemon-reload"

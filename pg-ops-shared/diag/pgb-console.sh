#!/usr/bin/env bash
# pgb-console.sh —— 免记口令连 PgBouncer 管理库
#
# 用在什么场景：想看某个实例的 SHOW POOLS / SHOW STATS / SHOW CLIENTS，又不想翻 userlist.txt
# 找口令。从 /etc/pgbouncer/*.ini 读端口与 admin_users，口令优先取 PGBOUNCER_PASS 环境变量，
# 否则读 auth_file（userlist.txt）里该用户的明文行。
#
# 用法： sudo bash pgb-console.sh                       # 遍历全部实例，SHOW POOLS
#        sudo bash pgb-console.sh 7432                  # 只查 7432，SHOW POOLS
#        sudo bash pgb-console.sh 7432 'SHOW STATS'      # 指定实例 + SQL
#        sudo PGBOUNCER_PASS=xxx bash pgb-console.sh     # 口令与 userlist 不一致时（如非 pg-ops 装的机器）
#
# 只取 ini 的 unix_socket_dir / listen_port / admin_users / auth_file，不碰任何主机名字段；
# 口令只经子进程环境传给 psql，不写文件、不 echo、不进 argv；不开 set -x。

set -euo pipefail

ARG_PORT="${1:-}"
SQL="${2:-SHOW POOLS}"

shopt -s nullglob
INIS=(/etc/pgbouncer/*.ini)
shopt -u nullglob

if [[ "${#INIS[@]}" -eq 0 ]]; then
    echo "problem: 找不到 /etc/pgbouncer/*.ini" >&2
    echo "cause: PgBouncer 未装，或配置目录不是 /etc/pgbouncer" >&2
    echo "fix: 确认 pg-dev-server 已完整装机，或检查该机 PgBouncer 的实际配置路径" >&2
    exit 1
fi

declare -A PORT_SOCK PORT_ADMIN PORT_AUTHFILE

for ini in "${INIS[@]}"; do
    [[ -r "${ini}" ]] || continue
    port="$(awk -F'=' '/^[[:space:]]*listen_port[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "${ini}")"
    [[ -n "${port}" ]] || continue
    sock="$(awk -F'=' '/^[[:space:]]*unix_socket_dir[[:space:]]*=/{sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/,"",$2); print $2; exit}' "${ini}")"
    admin="$(awk -F'=' '/^[[:space:]]*admin_users[[:space:]]*=/{print $2; exit}' "${ini}" | tr -d '[:space:]' | cut -d',' -f1)"
    authfile="$(awk -F'=' '/^[[:space:]]*auth_file[[:space:]]*=/{sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/,"",$2); print $2; exit}' "${ini}")"
    PORT_SOCK["${port}"]="${sock:-/var/run/postgresql}"
    PORT_ADMIN["${port}"]="${admin:-pgbouncer}"
    PORT_AUTHFILE["${port}"]="${authfile:-/etc/pgbouncer/userlist.txt}"
done

if [[ "${#PORT_SOCK[@]}" -eq 0 ]]; then
    echo "problem: 读遍了 /etc/pgbouncer/*.ini 也没找到 listen_port" >&2
    echo "cause: ini 格式与预期不同，或都读不到（权限？）" >&2
    echo "fix: 以 root 重跑，或手动核对 ini 的 [pgbouncer] 段" >&2
    exit 1
fi

if [[ -n "${ARG_PORT}" ]]; then
    PORTS=("${ARG_PORT}")
else
    PORTS=("${!PORT_SOCK[@]}")
fi

run_one() {
    local port="$1" sock user authfile pass out
    sock="${PORT_SOCK[${port}]:-}"
    user="${PORT_ADMIN[${port}]:-pgbouncer}"
    authfile="${PORT_AUTHFILE[${port}]:-/etc/pgbouncer/userlist.txt}"

    if [[ -z "${sock}" ]]; then
        echo "problem: 端口 ${port} 不在已发现的实例列表中" >&2
        echo "cause: 没有任何 /etc/pgbouncer/*.ini 的 listen_port 等于 ${port}" >&2
        echo "fix: 核对端口号，或不传端口让脚本遍历全部实例" >&2
        return 1
    fi

    pass="${PGBOUNCER_PASS:-}"
    if [[ -z "${pass}" && -r "${authfile}" ]]; then
        pass="$(sed -n "s/^\"${user}\" \"\\(.*\\)\"\$/\\1/p" "${authfile}" | head -1)"
    fi

    echo "--- 端口 ${port}（${user}@pgbouncer 管理库）---"

    if out="$(PGPASSWORD="${pass}" psql -X -w -P pager=off -h "${sock}" -p "${port}" -U "${user}" pgbouncer -c "${SQL}" 2>&1)"; then
        printf '%s\n' "${out}"
        return 0
    fi
    if out="$(PGPASSWORD="${pass}" psql -X -w -P pager=off -h 127.0.0.1 -p "${port}" -U "${user}" pgbouncer -c "${SQL}" 2>&1)"; then
        printf '%s\n' "${out}"
        return 0
    fi

    echo "problem: 连端口 ${port} 管理库失败（socket 与 127.0.0.1 均失败）" >&2
    echo "cause: 口令与 admin_users 不匹配，或该 PgBouncer 实例未起" >&2
    echo "fix: unset PGBOUNCER_PASS 让脚本回退读 userlist，或核对 ini 的 admin_users 与 systemctl status pgbouncer 相关服务" >&2
    return 1
}

RC=0
for port in "${PORTS[@]}"; do
    run_one "${port}" || RC=1
    echo ""
done
exit "${RC}"

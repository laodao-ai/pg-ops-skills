#!/usr/bin/env bash
# pg-conn-audit.sh —— 一次性回答「应用走了池还是直连、每个连接干了几个事务」
#
# 用在什么场景：装机刚完成想验证「走池 / 隧道直连」的判据是否成立；或项目接入后想看某个时刻
# 谁在连 5432、连接池有没有真的把连接摊薄。报告型脚本：只读、始终 0 退出，供人眼判读或塞进
# 装机自检。
#
# 三段：
#   A. ss 按客户端进程名给 5432 上的已建立连接分类（pgbouncer=走池 / sshd=隧道直连 / 其它）
#   B. pg_stat_database 采样窗口两端的差分：每库 Δ事务 / Δ会话 / 每连接事务数
#   C. pg_stat_activity 按 application_name / client_addr 分组的当前连接数
#
# 用法： sudo bash pg-conn-audit.sh [采样秒数]   （默认 10；装机自检用 5）
#
# 全部 PG 查询走 `sudo -u postgres psql -X -w -At` 经 unix socket（peer 认证），不依赖网络口令 /
# .pgpass。任一 psql 失败只提示不中止——这是报告脚本，不是探活脚本。

set -euo pipefail

DUR="${1:-10}"

psu() {
    sudo -u postgres psql -X -w -At -F'|' "$@"
}

# ───────────────────────── A. ss 快照（先于任何 psql 连接）─────────────────────────
echo "=== A. 5432 客户端连接分类（按进程名）==="
echo ""

IS_ROOT=0
[[ "$(id -u)" == "0" ]] && IS_ROOT=1
[[ "${IS_ROOT}" == "1" ]] || echo "  [!] 不是 root：拿不到进程名，无法归因的连接计入「其它」"

PGB_N=0 SSHD_N=0 OTHER_N=0
declare -A OTHER_NAMES
SS_LINES="$(ss -tnpH '( dport = :5432 )' 2>/dev/null || true)"

if [[ -z "${SS_LINES}" ]]; then
    echo "  当前无 5432 客户端连接"
else
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        if [[ "${line}" =~ users:\(\(\"([^\"]+)\" ]]; then
            proc="${BASH_REMATCH[1]}"
        else
            proc=""
        fi
        case "${proc}" in
            pgbouncer) PGB_N=$((PGB_N + 1)) ;;
            sshd)      SSHD_N=$((SSHD_N + 1)) ;;
            "")        OTHER_N=$((OTHER_N + 1)); OTHER_NAMES["(无进程名，需 root)"]=1 ;;
            *)         OTHER_N=$((OTHER_N + 1)); OTHER_NAMES["${proc}"]=1 ;;
        esac
    done <<< "${SS_LINES}"

    echo "  走池（pgbouncer）  : ${PGB_N}"
    echo "  隧道直连（sshd）   : ${SSHD_N}"
    echo "  其它               : ${OTHER_N}"
    if [[ "${OTHER_N}" -gt 0 ]]; then
        for n in "${!OTHER_NAMES[@]}"; do
            echo "    - ${n}"
        done
    fi
fi

# ───────────────────────── B. pg_stat_database 差分 ─────────────────────────
echo ""
echo "=== B. 每库每连接事务数（采样窗口 ${DUR}s）==="
echo ""

PGSD_SQL="SELECT s.datname, s.xact_commit, s.sessions
          FROM pg_stat_database s JOIN pg_database d ON d.oid = s.datid
          WHERE s.datname IS NOT NULL AND NOT d.datistemplate"

T0="$(psu -c "${PGSD_SQL}" 2>/dev/null)" \
    || { echo "[!] pg_stat_database（t0）查询失败，跳过段 B"; T0=""; }

if [[ -n "${T0}" ]]; then
    sleep "${DUR}"
    T1="$(psu -c "${PGSD_SQL}" 2>/dev/null)" \
        || { echo "[!] pg_stat_database（t1）查询失败，跳过段 B"; T1=""; }

    if [[ -n "${T1}" ]]; then
        printf "  %-20s %10s %10s %14s\n" "库" "Δ事务" "Δ会话" "每连接事务数"
        while IFS='|' read -r db xact0 sess0; do
            [[ -n "${db}" ]] || continue
            line1="$(printf '%s\n' "${T1}" | awk -F'|' -v d="${db}" '$1==d{print}')"
            [[ -n "${line1}" ]] || continue
            xact1="$(printf '%s' "${line1}" | cut -d'|' -f2)"
            sess1="$(printf '%s' "${line1}" | cut -d'|' -f3)"
            dxact=$((xact1 - xact0))
            dsess=$((sess1 - sess0))
            if [[ "${dsess}" -le 0 ]]; then
                printf "  %-20s %10s %10s  窗口内无新建连接，无法算每连接事务数\n" "${db}" "${dxact}" "0"
            else
                per="$(awk -v x="${dxact}" -v s="${dsess}" 'BEGIN{printf "%.1f", x/s}')"
                printf "  %-20s %10s %10s %14s\n" "${db}" "${dxact}" "${dsess}" "${per}"
            fi
        done <<< "${T0}"
    fi
fi

# ───────────────────────── C. pg_stat_activity 分组 ─────────────────────────
echo ""
echo "=== C. 当前连接（按 application_name / client_addr 分组，已排除自身）==="
echo ""

ACT="$(psu -c "
    SELECT coalesce(application_name,'-'), coalesce(host(client_addr),'local'), count(*)
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
    GROUP BY 1,2
    ORDER BY 3 DESC" 2>/dev/null)" || { echo "[!] pg_stat_activity 查询失败"; ACT=""; }

if [[ -n "${ACT}" ]]; then
    printf "  %-24s %-20s %8s\n" "application_name" "client_addr" "连接数"
    while IFS='|' read -r app addr n; do
        [[ -n "${app}" ]] || continue
        printf "  %-24s %-20s %8s\n" "${app}" "${addr}" "${n}"
    done <<< "${ACT}"
elif [[ -z "${ACT}" ]]; then
    echo "  （无其它连接，或查询失败见上）"
fi

echo ""
echo "注：不打印 query 文本；每连接事务数 < 10 多半说明连一次只干一两件事就断，池没起作用。"

exit 0

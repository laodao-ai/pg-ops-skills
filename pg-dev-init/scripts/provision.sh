#!/usr/bin/env bash
# pg-dev-init —— 在已装好的开发服务器（pg-dev-server）上为一个项目建库 + owner 角色（+ scratch 库）。
# 幂等：角色已存在只按 DB_PASS 同步口令（DB_PASS 留空则不动）；库已存在不碰数据。
# 建出的角色经 PgBouncer（auth_query）自动可登录，无需任何 PgBouncer 侧配置。
# 两种用法：
#   1) 渲染版（推荐）：scripts/render.sh pg-dev-init.env build/x.sh → 上服务器 sudo bash x.sh
#   2) 直接版：sudo bash provision.sh /path/to/pg-dev-init.env
set -euo pipefail

die()  { echo "problem: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok()   { echo "[✓] $*"; }

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    ENV_FILE="${1:?用法: sudo bash provision.sh <pg-dev-init.env>（或先用 render.sh 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# ---- 守卫①：env 参数校验 -------------------------------------------------------------
# 这一段只看 env、不碰服务器，所以 render.sh 在本机也跑它（PG_OPS_VALIDATE_ONLY=1），
# 让参数错误在 render 阶段就暴露，而不是 scp + ssh 之后才在服务器上炸。校验只有这一处，
# render 侧不复制——两处各写一份必然漂移。
[[ "${PG_OPS_ROLE:-}" == "dev" ]] || die "PG_OPS_ROLE 不是 dev（当前: ${PG_OPS_ROLE:-<空>}）。本脚本只允许在开发机执行"
: "${DB_NAME:?DB_NAME 必填}"
DB_USER="${DB_USER:-${DB_NAME}}"
DB_PASS="${DB_PASS:-}"
if [[ -n "${DB_PASS}" ]] && [[ "${DB_PASS}" =~ [\'\\\;] ]]; then
    die "DB_PASS 含非法字符（' \\ ;）；fix：换一个不含这些字符的口令，或留空自动生成"
fi
SCRATCH_DB="${SCRATCH_DB:-${DB_NAME}_scratch}"
[[ "${SCRATCH_DB}" != "none" ]] || SCRATCH_DB=""
[[ "${DB_NAME}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME 只允许小写字母 / 数字 / 下划线（当前: ${DB_NAME}）"
[[ "${DB_USER}" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_USER 只允许小写字母 / 数字 / 下划线（当前: ${DB_USER}）"
# 字符集合法不等于 PG 会接受：PG 另行保留 pg_ 前缀给系统角色，CREATE ROLE 直接拒
# （role name "pg_x" is reserved）。这是角色名的限制，CREATE DATABASE pg_x 本身合法——
# 所以只校验 DB_USER。库名被连坐只是因为本 skill 默认 owner 与库同名。
if [[ "${DB_USER}" =~ ^pg_ ]]; then
    if [[ "${DB_USER}" == "${DB_NAME}" ]]; then
        die "DB_NAME=${DB_NAME} 以 pg_ 开头：owner 角色默认与库同名，而 PG 保留 pg_ 前缀给系统角色，建角色会被拒；fix：改用 ${DB_NAME/pg_/pg}，或另行指定不以 pg_ 开头的 DB_USER"
    fi
    die "DB_USER=${DB_USER} 以 pg_ 开头：PG 保留该前缀给系统角色；fix：改用 ${DB_USER/pg_/pg}"
fi
CREATEDB="${CREATEDB:-}"
[[ -z "${CREATEDB}" || "${CREATEDB}" == "0" || "${CREATEDB}" == "1" ]] \
    || die "CREATEDB 只允许 0 / 1（当前: ${CREATEDB}）；fix：在 env 里把 CREATEDB 改成 0 或 1"
REDIS_DB="${REDIS_DB:-}"
if [[ -n "${REDIS_DB}" ]]; then
    if [[ "${REDIS_DB}" == "0" ]]; then
        die "REDIS_DB=0：0 保留给人手工探查，不可分配（fix：改用 1 起的编号，或留空自动分配）"
    fi
    [[ "${REDIS_DB}" =~ ^[1-9][0-9]*$ ]] || die "REDIS_DB 格式非法（当前: ${REDIS_DB}），只允许正整数"
fi

# render.sh 的本机预检到此为止——以上全是纯参数判断，以下开始要 root 与真实服务。
[[ -z "${PG_OPS_VALIDATE_ONLY:-}" ]] || { ok "env 校验通过（DB_NAME=${DB_NAME} / DB_USER=${DB_USER}）"; exit 0; }

# ---- 守卫②：服务器侧（要求 root 与已装好的 pg-dev-server）--------------------------------
[[ "$(id -u)" -eq 0 ]] || die "需要 root（sudo）"
pg_isready -h 127.0.0.1 -p 5432 >/dev/null || die "5432 不可达：这台机还没跑过 pg-dev-server 装机？"
[[ -r /etc/pgbouncer/pgbouncer.ini ]] && grep -q '^auth_query' /etc/pgbouncer/pgbouncer.ini \
    || die "PgBouncer 未配置 auth_query：请先用最新 pg-dev-server 重跑装机（旧版 userlist 模式不认新角色）"
PGB_PORT="$(sed -n 's/^listen_port *= *//p' /etc/pgbouncer/pgbouncer.ini | head -1)"
PGB_PORT="${PGB_PORT:-6432}"
# session 模式第二实例（新版 pg-dev-server 才有）；没有就留空，文档里标明
PGB_SESSION_PORT=""
[[ -r /etc/pgbouncer/pgbouncer-session.ini ]] && PGB_SESSION_PORT="$(sed -n 's/^listen_port *= *//p' /etc/pgbouncer/pgbouncer-session.ini | head -1)"
PG_OPS_DIR=/opt/pg-ops
PROJECT_DOC="${PG_OPS_DIR}/projects/${DB_NAME}.md"
[[ -d "${PG_OPS_DIR}/bin" ]] || die "${PG_OPS_DIR} 不存在：请先用最新 pg-dev-server 重跑装机（它负责建这个目录并写服务器交接文档）"
# 自装到 bin/，可原地重跑
SELF="$(readlink -f "${BASH_SOURCE[0]}")"; SELF_DEST="${PG_OPS_DIR}/bin/pg-dev-init-${DB_NAME}.sh"
[[ "${SELF}" == "${SELF_DEST}" ]] || install -m 700 "${SELF}" "${SELF_DEST}"
command -v perl >/dev/null || die "缺 perl（Ubuntu 自带，不该缺）"

psql_su() { sudo -u postgres env PGOPTIONS='-c client_min_messages=warning' psql -v ON_ERROR_STOP=1 -qtAX "$@"; }
# 含口令的语句会话级关掉 log_statement，避免明文进 PG 日志
psql_su_secret() { sudo -u postgres env PGOPTIONS='-c log_statement=none' psql -v ON_ERROR_STOP=1 -qtAX "$@"; }

# ---- Redis db 分配（纯文件输入，不碰 root/PG/Redis，可本地 fixture 自测）--------------------
# 用法：alloc_redis_db <projects_dir> <own_doc> <max_db>；stdout 只打分配到的数字
# 顺序：① own_doc 已有行 ⇒ 沿用（先于一切扫描；REDIS_DB 非空且不等则 die）
#      ② 否则 REDIS_DB 非空 ⇒ 校验范围 / 撞号后使用
#      ③ 否则从 1 起扫描 <projects_dir>/*.md（排除 own_doc）的已用集合，取第一个空号
alloc_redis_db() {
    local projects_dir="$1" own_doc="$2" max_db="$3"
    local re='^\|[[:space:]]*Redis db[[:space:]]*\|[[:space:]]*`([0-9]+)`'
    local own_line=""
    if [[ -n "${own_doc}" && -r "${own_doc}" ]]; then
        own_line="$(sed -nE "s/${re}.*/\\1/p" "${own_doc}" | head -1)"
    fi
    if [[ -n "${own_line}" ]]; then
        if [[ -n "${REDIS_DB:-}" && "${REDIS_DB}" != "${own_line}" ]]; then
            die "REDIS_DB=${REDIS_DB} 与文档 ${own_doc} 已分配的 ${own_line} 不一致；fix：留空沿用 ${own_line}，或先改文档"
        fi
        echo "${own_line}"
        return 0
    fi

    local used=() f n
    shopt -s nullglob
    for f in "${projects_dir}"/*.md; do
        if [[ -n "${own_doc}" && -e "${own_doc}" ]]; then
            [[ "$(realpath "${f}")" == "$(realpath "${own_doc}")" ]] && continue
        fi
        n="$(sed -nE "s/${re}.*/\\1/p" "${f}" | head -1)"
        [[ -n "${n}" ]] && used+=("${n}")
    done
    shopt -u nullglob

    if [[ -n "${REDIS_DB:-}" ]]; then
        (( REDIS_DB <= max_db )) || die "REDIS_DB=${REDIS_DB} 超出范围（1..${max_db}，databases=$((max_db + 1))）"
        for n in ${used[@]+"${used[@]}"}; do
            [[ "${n}" == "${REDIS_DB}" ]] && die "REDIS_DB=${REDIS_DB} 已被其它项目文档占用（见 ${projects_dir}）"
        done
        echo "${REDIS_DB}"
        return 0
    fi

    local i taken
    for (( i = 1; i <= max_db; i++ )); do
        taken=""
        for n in ${used[@]+"${used[@]}"}; do
            [[ "${n}" == "${i}" ]] && { taken=1; break; }
        done
        [[ -z "${taken}" ]] && { echo "${i}"; return 0; }
    done
    die "Redis db 已分完（databases=$((max_db + 1))），在 /etc/redis/redis.conf 调大 databases 后重跑"
}

# 分配（在任何角色 / 数据库写操作之前完成）：max_db 只取数字段，缺失/空值回落 16
[[ -r /etc/redis/redis.conf ]] || die "Redis 未安装或配置不可读（/etc/redis/redis.conf）" "Redis db 分配需要读 databases 行" "先用 pg-dev-server 装机，或确认 Redis 已安装"
REDIS_CONF_LINE="$(sed -nE 's/^databases[[:space:]]+([0-9]+).*/\1/p' /etc/redis/redis.conf 2>/dev/null | head -1)"
MAX_REDIS_DB=$(( ${REDIS_CONF_LINE:-16} - 1 ))
REDIS_DB_SRC=""
[[ -r "${PROJECT_DOC}" ]] && grep -qE '^\|[[:space:]]*Redis db[[:space:]]*\|' "${PROJECT_DOC}" && REDIS_DB_SRC="doc"
[[ -z "${REDIS_DB_SRC}" && -n "${REDIS_DB}" ]] && REDIS_DB_SRC="env"
REDIS_DB="$(alloc_redis_db "${PG_OPS_DIR}/projects" "${PROJECT_DOC}" "${MAX_REDIS_DB}")"
case "${REDIS_DB_SRC}" in
    doc) ok "Redis db：${REDIS_DB}（沿用文档）" ;;
    env) ok "Redis db：${REDIS_DB}（env 指定）" ;;
    *)   ok "Redis db：${REDIS_DB}（自动分配）" ;;
esac

# ---- 1. 角色 -------------------------------------------------------------------------
if [[ "$(psql_su -c "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" != "1" ]]; then
    if [[ -z "${DB_PASS}" ]]; then
        DB_PASS="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
        PASS_AUTO_GENERATED=1
    fi
    psql_su_secret -c "CREATE ROLE \"${DB_USER}\" LOGIN PASSWORD '${DB_PASS}'"
    ok "角色 ${DB_USER} 已建"
elif [[ -n "${DB_PASS}" ]]; then
    psql_su_secret -c "ALTER ROLE \"${DB_USER}\" PASSWORD '${DB_PASS}'"
    ok "角色 ${DB_USER} 已存在，口令已按 DB_PASS 更新"
else
    # 口令未给且角色已存在：从上次写的项目文档里取回，交接文档才能完整
    if [[ -r "${PROJECT_DOC}" ]]; then
        DB_PASS="$(sed -n 's/^| 口令 | `\([^`]*\)` |.*/\1/p' "${PROJECT_DOC}" | head -1)"
    fi
    ok "角色 ${DB_USER} 已存在，口令保持不变（要换密请填 DB_PASS）$([[ -n "${DB_PASS}" ]] && echo '，已从项目文档取回')"
fi

# ---- CREATEDB（只授不收，幂等）--------------------------------------------------------
CREATEDB_STATE_RAW="$(psql_su -c "SELECT rolcreatedb FROM pg_roles WHERE rolname='${DB_USER}'")"
if [[ "${CREATEDB}" == "1" && "${CREATEDB_STATE_RAW}" != "t" ]]; then
    psql_su -c "ALTER ROLE \"${DB_USER}\" CREATEDB"
    CREATEDB_STATE_RAW="t"
    ok "CREATEDB 已授予 ${DB_USER}"
elif [[ "${CREATEDB}" == "1" ]]; then
    ok "CREATEDB 已有，跳过"
fi
CREATEDB_STATE="否"
[[ "${CREATEDB_STATE_RAW}" == "t" ]] && CREATEDB_STATE="是"

# ---- 2. 库 ---------------------------------------------------------------------------
for db in "${DB_NAME}" ${SCRATCH_DB:+"${SCRATCH_DB}"}; do
    if [[ "$(psql_su -c "SELECT 1 FROM pg_database WHERE datname='${db}'")" != "1" ]]; then
        psql_su -c "CREATE DATABASE \"${db}\" OWNER \"${DB_USER}\" ENCODING 'UTF8' TEMPLATE template0"
        ok "库 ${db} 已建（owner ${DB_USER}）"
    else
        ok "库 ${db} 已存在，跳过（数据不动）"
    fi
done

# ---- 3. 探活：知道口令时走 PgBouncer 真登录一次；不知道时只验库存在 -----------------------
if [[ -n "${DB_PASS}" ]]; then
    PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -p "${PGB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -qtAXc "SELECT current_database()" >/dev/null \
        || die "探活失败：经 PgBouncer ${PGB_PORT} 以 ${DB_USER} 登录 ${DB_NAME} 失败（看 /var/log/postgresql/pgbouncer.log）"
    ok "经 PgBouncer ${PGB_PORT}（transaction）以 ${DB_USER} 登录 ${DB_NAME} 成功"
    if [[ -n "${PGB_SESSION_PORT}" ]]; then
        PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -p "${PGB_SESSION_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -qtAXc "SELECT current_database()" >/dev/null \
            || die "探活失败：经 PgBouncer ${PGB_SESSION_PORT}（session）以 ${DB_USER} 登录 ${DB_NAME} 失败（看 /var/log/postgresql/pgbouncer-session.log）"
        ok "经 PgBouncer ${PGB_SESSION_PORT}（session）以 ${DB_USER} 登录 ${DB_NAME} 成功"
    fi
else
    ok "口令未知（保持原值），跳过登录探活"
fi

# ---- 4. 项目交接文档：写到服务器 /opt/pg-ops/projects/<库名>.md，新项目 / 新同事 sudo cat 即可 ----
render_doc() {
    local tpl
    if [[ -n "${PG_OPS_TEMPLATE_B64:-}" ]]; then
        tpl="$(printf '%s' "${PG_OPS_TEMPLATE_B64}" | base64 -d)"
    else
        tpl="$(cat "$(dirname "${BASH_SOURCE[0]}")/../templates/project.md")"
    fi
    printf '%s\n' "${tpl}" | perl -pe 's/\{\{(\w+)\}\}/exists $ENV{$1} ? $ENV{$1} : "<未填 $1>"/ge' > "$1"
    chmod 600 "$1"
}
mkdir -p "${PG_OPS_DIR}/projects"
export GENERATED_AT="$(date '+%F %T')" DB_NAME DB_USER DB_PASS="${DB_PASS:-<未知：角色早于本工具建立，填 DB_PASS 换密后重跑即可记录>}" \
       SCRATCH_DB="${SCRATCH_DB:-（未建）}" PGB_PORT PGB_SESSION_PORT="${PGB_SESSION_PORT:-<未装：服务器还是单实例 PgBouncer，用最新 pg-dev-server 重跑装机即有>}" PG_OPS_DIR \
       CREATEDB_STATE REDIS_DB
render_doc "${PROJECT_DOC}"
[[ "${PASS_AUTO_GENERATED:-}" == "1" ]] && ok "口令已写入 ${PROJECT_DOC}"
ok "项目交接文档已写入 ${PROJECT_DOC}（取回命令见末尾）"

cat <<SUMMARY

=== 完成。交给项目的连接信息（服务器侧地址，开发机经隧道后同样端口）===
取回（开发机执行）：bash <skill-dir>/scripts/pgops-fetch.sh <host> ${PROJECT_DOC}
库：${DB_NAME}${SCRATCH_DB:+（scratch: ${SCRATCH_DB}）}   用户：${DB_USER}   CREATEDB：${CREATEDB_STATE}   Redis db：${REDIS_DB}
应用 / 集成测试（transaction 池）：  postgres://${DB_USER}:<口令>@127.0.0.1:${PGB_PORT}/${DB_NAME}
要会话级特性又经池子（session 池）：postgres://${DB_USER}:<口令>@127.0.0.1:${PGB_SESSION_PORT:-<未装>}/${DB_NAME}
迁移 / pg_restore（直连）：          postgres://${DB_USER}:<口令>@127.0.0.1:5432/${DB_NAME}
SUMMARY

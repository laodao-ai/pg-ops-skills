#!/usr/bin/env bash
# pg-dev-server —— Ubuntu 装机：PostgreSQL <PG_MAJOR> + PgBouncer（事务池，auth_query）+ Redis，全部回环监听。
# 只装服务器基础环境，不建任何项目的库 / 角色（那些由 pg-dev-init 生成的脚本做）。
# 幂等：已装的包跳过；配置文件整份重写（本脚本 owns 它们）但不动数据目录；PG 配置没变就不重启。
# 三种用法：
#   1) 渲染版（推荐）：scripts/render.sh pg-dev-server.env build/install.sh → 上服务器 sudo bash install.sh
#   2) 直接版：sudo bash install-ubuntu.sh /path/to/pg-dev-server.env
#   3) 只重生成交接文档（不装包、不改配置、不重启，口令按服务器现有的）：
#      sudo env PG_OPS_DOCS_ONLY=1 bash /opt/pg-ops/bin/pg-dev-server-install.sh
set -euo pipefail

die()  { echo "problem: $*" >&2; exit 1; }
# unattended-upgrades 常在首次装包后立刻抢 dpkg 锁；apt-get 等锁最多 10 分钟而不是直接报错
apt-get() { DEBIAN_FRONTEND=noninteractive command apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Use-Pty=0 "$@"; }
info() { echo "[*] $*"; }
ok()   { echo "[✓] $*"; }

if [[ -z "${PG_OPS_RENDERED:-}" ]]; then
    ENV_FILE="${1:?用法: sudo bash install-ubuntu.sh <pg-dev-server.env>（或先用 render.sh 渲染）}"
    [[ -r "${ENV_FILE}" ]] || die "读不到 ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# ---- 守卫：生产 / 发行版 / root ----------------------------------------------------
[[ "${PG_OPS_ROLE:-}" == "dev" ]] || die "PG_OPS_ROLE 不是 dev（当前: ${PG_OPS_ROLE:-<空>}）。本脚本会重写 PG / PgBouncer / Redis 配置，只允许在开发机执行"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "只支持 Ubuntu（检测到 ID=${ID:-unknown}）。其它发行版另写 install-<os>.sh"
[[ "$(id -u)" -eq 0 ]] || die "需要 root（sudo）"

: "${PG_MAJOR:?}" "${SSH_TARGET:=<host>}" "${DATA_ROOT:=}" "${PGDG_MIRROR:=}" "${PGB_PORT:=6432}" "${PGB_SESSION_PORT:=7432}" "${PGB_MAX_CLIENT_CONN:=200}" "${PGB_DEFAULT_POOL_SIZE:=20}" \
  "${PGB_AUTH_PASS:=}" "${REDIS_PORT:=6379}" "${REDIS_PASS:=}" "${PG_SUPER_PASS:=}" "${PUBLIC_IP:=}" \
  "${SWAP_GB:=2}" "${PG_SHARED_BUFFERS:=256MB}" "${REDIS_MAXMEMORY:=256mb}" "${REDIS_MAXMEMORY_POLICY:=volatile-lru}" "${PG_STAT_STATEMENTS_MAX:=50000}"
# 淘汰策略值域早失败：写进 redis.conf 后 Redis 起不来才发现太晚。*-lrm 是 Redis 8.6 新增，更早的版本会在启动时自己拒绝
[[ "${REDIS_MAXMEMORY_POLICY}" =~ ^(noeviction|(allkeys|volatile)-(lru|lfu|lrm|random)|volatile-ttl)$ ]] \
    || die "REDIS_MAXMEMORY_POLICY 非法: ${REDIS_MAXMEMORY_POLICY}（可选 noeviction / allkeys-{lru,lfu,lrm,random} / volatile-{lru,lfu,lrm,random,ttl}）"
[[ "${REDIS_PASS}" != "CHANGE_ME" ]] || REDIS_PASS=""
[[ "${PG_SUPER_PASS}" != "CHANGE_ME" ]] || PG_SUPER_PASS=""
command -v perl >/dev/null || die "缺 perl（Ubuntu 自带，不该缺）"
PG_OPS_DIR=/opt/pg-ops      # 本工具在服务器上的家：bin/（脚本，可原地重跑）· README.md · handover.md · projects/<库名>.md · postgres.pass
REDIS_CONF=/etc/redis/redis.conf
PG_SUPER_PASS_FILE="${PG_OPS_DIR}/postgres.pass"   # postgres 超级用户口令（root 600）；scram 哈希读不回明文，所以单独存一份供重跑沿用与写文档
# 把正在执行的这份脚本自装到 bin/，之后 sudo bash /opt/pg-ops/bin/pg-dev-server-install.sh 即可原地重跑
mkdir -p "${PG_OPS_DIR}/bin" "${PG_OPS_DIR}/projects"; chmod 700 "${PG_OPS_DIR}" "${PG_OPS_DIR}/bin" "${PG_OPS_DIR}/projects"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"; SELF_DEST="${PG_OPS_DIR}/bin/pg-dev-server-install.sh"
[[ "${SELF}" == "${SELF_DEST}" ]] || install -m 700 "${SELF}" "${SELF_DEST}"

# ---- 诊断脚本：内嵌 tgz 优先，未经 render 的直接版回退拷贝仓内 pg-ops-shared/diag/，两者都没有就跳过 ----
install_diag() {
    local diag_dir="${PG_OPS_DIR}/bin/diag"
    if [[ -n "${PG_OPS_DIAG_TGZ_B64:-}" ]]; then
        rm -rf "${diag_dir}"    # 整份重写语义：源里删掉的脚本目标机也随之消失
        if ! printf '%s' "${PG_OPS_DIAG_TGZ_B64}" | base64 -d | tar xzf - -C "${PG_OPS_DIR}/bin" 2>/dev/null; then
            die "内嵌诊断脚本包解不开；cause: PG_OPS_DIAG_TGZ_B64 损坏或传输截断；fix: 用 render.sh 重渲染一份再上传"
        fi
        chmod 755 "${diag_dir}"/*.sh 2>/dev/null || true
        ok "诊断脚本已装到 ${diag_dir}"
    else
        local src_diag; src_diag="$(dirname "${BASH_SOURCE[0]}")/../../pg-ops-shared/diag"
        if [[ -d "${src_diag}" ]]; then
            rm -rf "${diag_dir}"
            cp -r "${src_diag}" "${diag_dir}"
            chmod 755 "${diag_dir}"/*.sh 2>/dev/null || true
            ok "诊断脚本已从仓内 ${src_diag} 拷贝到 ${diag_dir}（直接版用法，未经 render.sh）"
        else
            info "跳过诊断脚本安装：PG_OPS_DIAG_TGZ_B64 为空且 ${src_diag} 不存在"
        fi
    fi
}
install_diag

cat > "${PG_OPS_DIR}/README.md" <<'README'
# /opt/pg-ops —— 开发数据库服务器上的 pg-ops 工具目录（root 700）

由 pg-ops skill 仓（pg-dev-server / pg-dev-init）生成的脚本在执行时自动装到这里，可原地重跑，全部幂等。

| 路径 | 是什么 | 怎么用 |
|---|---|---|
| `bin/pg-dev-server-install.sh` | 装机脚本（参数已内联）：PG + PgBouncer + Redis 基础环境 | `sudo bash bin/pg-dev-server-install.sh` 重跑；改参数请在开发机改 env 重新渲染上传。只想刷新交接文档：`sudo env PG_OPS_DOCS_ONLY=1 bash bin/pg-dev-server-install.sh`（不装包不改配置不重启） |
| `bin/pg-dev-init-<库名>.sh` | 某项目的建库脚本（库 + owner 角色 + scratch 库） | `sudo bash bin/pg-dev-init-<库名>.sh` 重跑；换密在开发机填 DB_PASS 重渲染 |
| `bin/diag/` | 只读诊断脚本（随装机内嵌，重跑刷新） | `sudo bash bin/diag/<脚本>.sh`，用法见 `sudo cat bin/diag/README.md` |
| `handover.md` | 服务器交接文档：信息 / postgres 与 Redis 口令 / 隧道 / PgBouncer 两种模式怎么选 / 安全配置 / 运维 | 服务器上 `sudo cat handover.md`；开发机取回用 pg-ops skill 的 pgops-fetch.sh |
| `projects/<库名>.md` | 各项目库的账号口令与连接串 | `sudo ls projects/`、`sudo cat projects/<库名>.md` |
| `postgres.pass` | 超级用户 `postgres` 的网络口令（装机脚本首次生成、之后沿用） | 换密：删掉此文件后重跑装机（自动生成新口令），或开发机 env 填 `PG_SUPER_PASS` 重渲染 |

新项目接入这台服务器：先 `sudo cat handover.md` 拿隧道与 Redis 信息，再让 pg-dev-init 生成建库脚本上传执行，
账号会出现在 `projects/`。本目录含口令，权限保持 700，不要复制到任何仓库。
README
chmod 600 "${PG_OPS_DIR}/README.md"

# ---- 口令：留空 = 沿用服务器上现有的（真相在服务器，env 不必保存）。只读不生成，生成在各自安装段做 ----
load_existing_secrets() {
    if [[ -z "${REDIS_PASS}" && -r "${REDIS_CONF}" ]]; then
        REDIS_PASS="$(sed -n 's/^requirepass \(.*\)$/\1/p' "${REDIS_CONF}" | head -1)"
    fi
    if [[ -z "${PG_SUPER_PASS}" && -r "${PG_SUPER_PASS_FILE}" ]]; then
        PG_SUPER_PASS="$(head -1 "${PG_SUPER_PASS_FILE}")"
    fi
}

# ---- 交接文档：写到服务器上，之后任何人 / 任何新项目 sudo cat 即可查到（完整装机末尾与 DOCS_ONLY 模式共用）----
render_doc() {   # render_doc <输出路径>：用 {{VAR}} 占位的模板 + 当前环境变量生成文档
    local tpl
    if [[ -n "${PG_OPS_TEMPLATE_B64:-}" ]]; then
        tpl="$(printf '%s' "${PG_OPS_TEMPLATE_B64}" | base64 -d)"
    else
        tpl="$(cat "$(dirname "${BASH_SOURCE[0]}")/../templates/handover.md")"
    fi
    printf '%s\n' "${tpl}" | perl -pe 's/\{\{(\w+)\}\}/exists $ENV{$1} ? $ENV{$1} : "<未填 $1>"/ge' > "$1"
    chmod 600 "$1"
}
write_handover() {
    local UFW_STATUS SSHD_STATUS HARDEN_BOX HARDEN_TODO SSH_SCOPE_DOC HANDOVER OLD_HARDEN_BLOCK
    if ufw status 2>/dev/null | grep -q "^Status: active"; then UFW_STATUS="已完成（ufw active）"; else UFW_STATUS="待做：跑 bin/pg-dev-server-harden.sh（见下）"; fi
    if [[ -f /etc/ssh/sshd_config.d/10-pg-ops.conf ]]; then SSHD_STATUS="已完成（10-pg-ops.conf）"; else SSHD_STATUS="待做：跑 bin/pg-dev-server-harden.sh（见下）"; fi
    if [[ -f /etc/ssh/sshd_config.d/10-pg-ops.conf ]] && ufw status 2>/dev/null | grep -q "^Status: active"; then
        HARDEN_BOX="x"; HARDEN_TODO="已执行（状态见第 4 节）。改 SSH 白名单或想复核时重跑 \`sudo bash ${PG_OPS_DIR}/bin/pg-dev-server-harden.sh\`。"
    else
        HARDEN_BOX=" "; HARDEN_TODO="**未执行**。跑 \`sudo bash ${PG_OPS_DIR}/bin/pg-dev-server-harden.sh\`（sshd 只密钥 / root 禁登、ufw 只放 22、fail2ban、自动更新），跑完另开一个 ssh 会话确认能登录再关旧会话。"
    fi
    if [[ -n "${SSH_ALLOW_FROM:-}" ]]; then
        SSH_SCOPE_DOC="当前只放行 \`${SSH_ALLOW_FROM}\`。出口 IP 变了要同步改安全组与 \`SSH_ALLOW_FROM\`（重跑加固）。"
    else
        SSH_SCOPE_DOC="当前 22 对任意来源开放（靠密钥 + fail2ban）。有固定出口 IP 时建议填 \`SSH_ALLOW_FROM\` 重跑加固，并在安全组同样收窄。"
    fi
    export UFW_STATUS SSHD_STATUS HARDEN_TODO HARDEN_BOX SSH_SCOPE_DOC
    export GENERATED_AT="$(date '+%F %T')" HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)" OS_PRETTY="${PRETTY_NAME:-Ubuntu}" \
           PG_VERSION="$(psql --version | awk '{print $3}')" PGB_VERSION="$(pgbouncer --version 2>&1 | head -1 | awk '{print $2}')" \
           REDIS_VERSION="$(redis-server --version | sed -n 's/.*v=\([^ ]*\).*/\1/p')" \
           SSH_TARGET PUBLIC_IP="${PUBLIC_IP:-<公网IP>}" PG_MAJOR PGB_PORT PGB_SESSION_PORT PGB_DEFAULT_POOL_SIZE REDIS_PORT REDIS_PASS="${REDIS_PASS:-<未设：跑一次完整装机>}" \
           PG_SUPER_PASS="${PG_SUPER_PASS:-<未设：跑一次完整装机>}" REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-不限}" REDIS_MAXMEMORY_POLICY \
           SWAP_GB DATA_ROOT="${DATA_ROOT:-/var/lib}" PG_OPS_DIR
    # 重跑装机时保留加固脚本写入的「主机加固状态」块（模板里只有「未执行」占位）
    HANDOVER="${PG_OPS_DIR}/handover.md"; OLD_HARDEN_BLOCK=""
    if [[ -f "${HANDOVER}" ]] && grep -q '<!-- harden:start -->' "${HANDOVER}"; then
        OLD_HARDEN_BLOCK="$(perl -0ne 'print $1 if /(<!-- harden:start -->.*?<!-- harden:end -->)/s' "${HANDOVER}")"
    fi
    render_doc "${HANDOVER}"
    if [[ -n "${OLD_HARDEN_BLOCK}" && "${OLD_HARDEN_BLOCK}" != *"未执行"* ]]; then
        BLOCK="${OLD_HARDEN_BLOCK}" perl -0pi -e 's/<!-- harden:start -->.*?<!-- harden:end -->/$ENV{BLOCK}/s' "${HANDOVER}"
    fi
    ok "交接文档已写入 ${PG_OPS_DIR}/handover.md（含 postgres 与 Redis 口令；查看：sudo cat ${PG_OPS_DIR}/handover.md）"
}

# ---- DOCS_ONLY：只重生成文档（模板改了 / 想刷新状态），到此为止。不装包、不改配置、不重启、不生成口令 ----
if [[ -n "${PG_OPS_DOCS_ONLY:-}" ]]; then
    [[ -f "${PG_OPS_DIR}/handover.md" ]] || die "PG_OPS_DOCS_ONLY 只能在装过的机器上用（没有 ${PG_OPS_DIR}/handover.md），请先完整装机"
    command -v psql >/dev/null && command -v pgbouncer >/dev/null && command -v redis-server >/dev/null \
        || die "PG_OPS_DOCS_ONLY：三个服务的包不全，请先完整装机"
    info "PG_OPS_DOCS_ONLY=1：只重生成交接文档，口令沿用服务器现有的"
    load_existing_secrets
    write_handover
    echo; echo "=== 完成（只写文档）。取回：bash <skill-dir>/scripts/pgops-fetch.sh ${SSH_TARGET} ${PG_OPS_DIR}/handover.md ==="
    exit 0
fi

# ---- 0. swap（小内存机兜底：2G 无 swap 时 pg_restore / 偶发大查询会被 OOM killer 直接杀 postgres）----
if [[ "${SWAP_GB}" != "0" ]]; then
    if swapon --show=NAME --noheadings | grep -q .; then
        ok "swap 已存在（$(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')），跳过"
    else
        info "建 /swapfile ${SWAP_GB}G"
        fallocate -l "${SWAP_GB}G" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "swap ${SWAP_GB}G 已启用并写入 fstab"
    fi
    # 数据库机上 swap 只做兜底、不做常态换页：swappiness 压低，避免 shared_buffers 被换出
    echo 'vm.swappiness = 10' > /etc/sysctl.d/90-pg-ops.conf
    sysctl -q -p /etc/sysctl.d/90-pg-ops.conf
fi

# ---- 0b. needrestart：只列不重启（MUST 在任何 apt-get install 之前）----------------
# 共享库（libssl / libc）打安全补丁后，needrestart 会重启还在用旧 so 的进程——postgresql、pgbouncer、
# redis-server 都在其列，且在交互式 apt 里是默认勾选的，回车即重启数据库。
# 这条路径与 unattended-upgrades 的包黑名单是**两回事**：黑名单只保证 PG 包本身不被升级，
# 而 libssl 照升、升完 needrestart 照样重启集群（PG 包一行没动，服务却断了）。
# 本脚本自己的 apt-get 已带 DEBIAN_FRONTEND=noninteractive，弹不出框；这里配置是为了保护
# **之后人工在这台机器上跑的每一次 apt**。改成 list only 后 needrestart 只打印清单，由人挑窗口自己重启。
# 写 conf.d/ 而不是改 needrestart.conf 本体：那份是发行版托管的，整份重写会和发行版升级打架。
NEEDRESTART_CONF=/etc/needrestart/conf.d/90-pg-ops.conf
if [[ -d /etc/needrestart/conf.d ]]; then
    cat > "${NEEDRESTART_CONF}" <<'EOF'
# managed by pg-ops/pg-dev-server —— 手改会被下次装机重写
# list only：apt 之后只打印"哪些服务需要重启"，不自动重启，也不弹交互框
$nrconf{restart} = 'l';
EOF
    ok "needrestart 设为 list only（${NEEDRESTART_CONF}）"
else
    info "未装 needrestart（无 /etc/needrestart/conf.d），跳过"
fi

# ---- 1. PGDG apt 源 + 三个包 ----------------------------------------------
PGDG_SOURCES=/etc/apt/sources.list.d/pgdg.sources
# PGDG 镜像：官方源在国内极慢，PGDG_MIRROR 非空时把 URIs 换成镜像。MUST 在任何 apt-get update 之前做，
# 否则 update 本身就卡在官方源上（幂等：每次按 env 重写）
apply_pgdg_mirror() {
    [[ -n "${PGDG_MIRROR}" && -f "${PGDG_SOURCES}" ]] || return 0
    grep -q "^URIs: ${PGDG_MIRROR}\$" "${PGDG_SOURCES}" && return 0
    sed -i -E "s|^URIs: .*|URIs: ${PGDG_MIRROR}|" "${PGDG_SOURCES}"
    ok "PGDG 源已切到镜像 ${PGDG_MIRROR}"
}
apply_pgdg_mirror
apt-get update -qq
# 注意不能用 grep -q：pipefail 下 grep 提前退出会让 apt-cache 收 SIGPIPE 返回非零，误判成"没有候选"
if ! apt-cache policy "postgresql-${PG_MAJOR}" 2>/dev/null | grep "Candidate: [0-9]" >/dev/null; then
    info "发行版没有 postgresql-${PG_MAJOR}，添加 PGDG apt 源"
    apt-get install -y -qq postgresql-common ca-certificates curl gnupg
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apply_pgdg_mirror
    apt-get update -qq
fi
# 数据盘：在装包（自动建集群）之前就告诉 postgresql-common 集群放哪，避免装到 /var/lib 再迁
if [[ -n "${DATA_ROOT}" ]]; then
    [[ -d "${DATA_ROOT}" ]] || die "DATA_ROOT=${DATA_ROOT} 不存在（数据盘没挂？）"
    mkdir -p /etc/postgresql-common/createcluster.d "${DATA_ROOT}/postgresql"
    cat > /etc/postgresql-common/createcluster.d/pg-ops.conf <<CONF
# managed by pg-ops/pg-dev-server —— 新建集群的数据目录放数据盘
data_directory = '${DATA_ROOT}/postgresql/%v/%c'
CONF
fi
info "安装 postgresql-${PG_MAJOR} pgbouncer redis-server（已装则跳过）"
apt-get install -y -qq "postgresql-${PG_MAJOR}" pgbouncer redis-server
ok "包就绪：$(psql --version) · $(pgbouncer --version 2>&1 | head -1) · $(redis-server --version | cut -d' ' -f1-3)"
if [[ -n "${DATA_ROOT}" ]]; then
    chown postgres:postgres "${DATA_ROOT}/postgresql"
    PG_DATA_ACTUAL="$(pg_lsclusters --no-header 2>/dev/null | awk -v v="${PG_MAJOR}" '$1==v && $2=="main"{print $6}')"
    PG_DATA_WANT="${DATA_ROOT}/postgresql/${PG_MAJOR}/main"
    if [[ "${PG_DATA_ACTUAL}" == "${PG_DATA_WANT}" ]]; then
        ok "PG 集群 ${PG_MAJOR}/main 数据目录在 ${PG_DATA_WANT}"
    else
        echo "[!] PG 集群 ${PG_MAJOR}/main 已在 ${PG_DATA_ACTUAL:-<未知>}，与 DATA_ROOT 不符。数据目录一律不动、不迁移；" >&2
        echo "    若确认是空集群可手动：sudo pg_dropcluster --stop ${PG_MAJOR} main && sudo pg_createcluster ${PG_MAJOR} main，再重跑本脚本" >&2
    fi
fi

# ---- 2. PostgreSQL：回环监听（Ubuntu 默认 localhost）、scram、基础审计参数、观测子集（桶 1）----
# pg_stat_statements.so 预检：先于写 conf，不把 postmaster 起不来的配置写下去
PGSS_SO="/usr/lib/postgresql/${PG_MAJOR}/lib/pg_stat_statements.so"
[[ -f "${PGSS_SO}" ]] || die "缺 ${PGSS_SO}；cause: postgresql-${PG_MAJOR} 包不含该扩展（非 PGDG / 精简包）；fix: apt-get install postgresql-contrib-${PG_MAJOR} 或检查 apt 源"
PG_CONF_D="/etc/postgresql/${PG_MAJOR}/main/conf.d"
mkdir -p "${PG_CONF_D}"
PG_CONF_BEFORE="$(md5sum "${PG_CONF_D}/90-pg-ops.conf" 2>/dev/null | cut -d' ' -f1)"
cat > "${PG_CONF_D}/90-pg-ops.conf" <<CONF
# managed by pg-ops/pg-dev-server —— 手改会被下次装机重写
listen_addresses = 'localhost'
password_encryption = 'scram-sha-256'
shared_buffers = ${PG_SHARED_BUFFERS}
log_connections = on
log_disconnections = on
log_statement = 'ddl'
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %u@%d app=%a '
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.max = ${PG_STAT_STATEMENTS_MAX}
track_io_timing = on
random_page_cost = 1.1
effective_io_concurrency = 200
jit = off
CONF
systemctl enable --now "postgresql@${PG_MAJOR}-main" >/dev/null 2>&1 || systemctl enable --now postgresql
# 部分参数（如 shared_buffers）只在启动时读取，reload 不生效；开发机接受一次重启。但配置没变（重跑装机）就不重启，不打断已有连接
if [[ "$(md5sum "${PG_CONF_D}/90-pg-ops.conf" | cut -d' ' -f1)" != "${PG_CONF_BEFORE}" ]]; then
    systemctl restart "postgresql@${PG_MAJOR}-main" 2>/dev/null || systemctl restart postgresql
    ok "PostgreSQL 配置写入 ${PG_CONF_D}/90-pg-ops.conf（shared_buffers=${PG_SHARED_BUFFERS}，pgss max=${PG_STAT_STATEMENTS_MAX}），已重启"
else
    ok "PostgreSQL 配置 ${PG_CONF_D}/90-pg-ops.conf 未变，不重启"
fi

psql_su() { sudo -u postgres env PGOPTIONS='-c client_min_messages=warning' psql -v ON_ERROR_STOP=1 -qtAX "$@"; }
# 含口令的语句用这个：会话级关掉 log_statement，否则 CREATE/ALTER ROLE ... PASSWORD 会以 DDL 明文进日志
psql_su_secret() { sudo -u postgres env PGOPTIONS='-c log_statement=none' psql -v ON_ERROR_STOP=1 -qtAX "$@"; }

# ---- 2a. pg_stat_statements 扩展：顺序固定在重启之后（.so 需先被加载）----
psql_su -d postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements' \
    || die "CREATE EXTENSION pg_stat_statements 失败；cause: 库可能未真正重启（.so 未加载）或预加载库未生效；fix: 确认上一步已重启，或手动 systemctl restart postgresql@${PG_MAJOR}-main 后重跑本脚本"
ok "postgres 库已就绪 pg_stat_statements 扩展"

# ---- 2b. 超级用户 postgres 的网络口令（DB 工具经隧道连 5432 看 / 管全部库用）----
# 口令留空：已设过则沿用 postgres.pass，首次则生成。只走 5432 直连；PgBouncer 的 auth_query 排除超级用户，6432 拒绝它
load_existing_secrets
[[ -n "${PG_SUPER_PASS}" ]] || PG_SUPER_PASS="$(openssl rand -hex 16)"
psql_su_secret -c "ALTER ROLE postgres PASSWORD '${PG_SUPER_PASS}'"
(umask 077; printf '%s\n' "${PG_SUPER_PASS}" > "${PG_SUPER_PASS_FILE}")
ok "超级用户 postgres 网络口令已设并记录到 ${PG_SUPER_PASS_FILE}（只经 5432 直连口登录）"

# ---- 3. PgBouncer 认证角色 + auth_query 函数（装一次，之后任何项目建的角色自动可经 PgBouncer 登录）----
PGB_USERLIST=/etc/pgbouncer/userlist.txt
if [[ -z "${PGB_AUTH_PASS}" ]]; then
    # 口令留空：已装过则复用 userlist 里的，首次则生成。这样重跑不会把口令换掉
    if [[ -r "${PGB_USERLIST}" ]] && grep -q '^"pgbouncer" ' "${PGB_USERLIST}"; then
        PGB_AUTH_PASS="$(sed -n 's/^"pgbouncer" "\(.*\)"$/\1/p' "${PGB_USERLIST}" | head -1)"
    fi
    [[ -n "${PGB_AUTH_PASS}" ]] || PGB_AUTH_PASS="$(openssl rand -hex 16)"
fi
if [[ "$(psql_su -c "SELECT 1 FROM pg_roles WHERE rolname='pgbouncer'")" != "1" ]]; then
    psql_su_secret -c "CREATE ROLE pgbouncer LOGIN PASSWORD '${PGB_AUTH_PASS}'"
    ok "PgBouncer 认证角色 pgbouncer 已建"
else
    psql_su_secret -c "ALTER ROLE pgbouncer PASSWORD '${PGB_AUTH_PASS}'"
    ok "PgBouncer 认证角色 pgbouncer 已存在，口令已同步"
fi
# 函数放 postgres 库（pgbouncer.ini 里 auth_dbname = postgres），SECURITY DEFINER 代 pgbouncer 角色读 pg_authid；
# 排除超级用户，避免 postgres 本身经池子登录
psql_su -d postgres <<'SQL'
CREATE SCHEMA IF NOT EXISTS pgbouncer AUTHORIZATION postgres;
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE(username text, password text)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT rolname::text,
         CASE WHEN rolvaliduntil < now() THEN NULL ELSE rolpassword END
  FROM pg_authid
  WHERE rolname = p_usename AND rolcanlogin AND NOT rolsuper
$$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer;
SQL
ok "auth_query 函数 pgbouncer.get_auth 就绪（postgres 库）"

# ---- 4. PgBouncer：两个实例、两种池模式按端口分开（userlist 只放认证角色自己，明文，供其登录后端）------
#   PGB_PORT         transaction：每个事务借一个服务端连接，事务结束归还。仅为兼容既有代码保留，不是缺省
#   PGB_SESSION_PORT session：    客户端连着就一直占一个服务端连接。**缺省经池子就用它**——会话级特性
#                                 （SET / advisory lock / LISTEN / SQL 级 PREPARE）全可用，功能与直连一致。
#                                 代价是空闲客户端也占着后端连接，同时连着的客户端数受 default_pool_size 约束。
#                                 两实例共用 userlist 与 auth_query
printf '"pgbouncer" "%s"\n' "${PGB_AUTH_PASS}" > "${PGB_USERLIST}"
chown postgres:postgres "${PGB_USERLIST}"; chmod 640 "${PGB_USERLIST}"
write_pgbouncer_ini() {   # write_pgbouncer_ini <ini 路径> <pool_mode> <端口> <实例名（日志 / pid 文件名）>
    cat > "$1" <<CONF
; managed by pg-ops/pg-dev-server —— 手改会被下次装机重写。实例 $4：pool_mode=$2，端口 $3
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $3
unix_socket_dir = /var/run/postgresql
auth_type = scram-sha-256
auth_file = ${PGB_USERLIST}
auth_user = pgbouncer
auth_dbname = postgres
auth_query = SELECT username, password FROM pgbouncer.get_auth(\$1)
pool_mode = $2
max_client_conn = ${PGB_MAX_CLIENT_CONN}
default_pool_size = ${PGB_DEFAULT_POOL_SIZE}
ignore_startup_parameters = extra_float_digits
admin_users = pgbouncer
logfile = /var/log/postgresql/$4.log
pidfile = /var/run/postgresql/$4.pid
CONF
    chown postgres:postgres "$1"; chmod 640 "$1"
}
write_pgbouncer_ini /etc/pgbouncer/pgbouncer.ini         transaction "${PGB_PORT}"         pgbouncer
write_pgbouncer_ini /etc/pgbouncer/pgbouncer-session.ini session     "${PGB_SESSION_PORT}" pgbouncer-session
# 发行版只带一个 pgbouncer.service（无多实例模板）；session 实例照抄它的写法另写一个单元
cat > /etc/systemd/system/pgbouncer-session.service <<UNIT
# managed by pg-ops/pg-dev-server —— PgBouncer 第二实例（session 模式，端口 ${PGB_SESSION_PORT}），手改会被下次装机重写
[Unit]
Description=connection pooler for PostgreSQL (session mode, pg-ops)
Documentation=https://www.pgbouncer.org/
After=network.target

[Service]
Type=notify
User=postgres
ExecStart=/usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer-session.ini
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now pgbouncer pgbouncer-session >/dev/null 2>&1
systemctl restart pgbouncer pgbouncer-session
ok "PgBouncer 两实例：127.0.0.1:${PGB_PORT} transaction · 127.0.0.1:${PGB_SESSION_PORT} session（auth_query，项目角色无需登记）"

# ---- 5. Redis：回环 + 口令 -----------------------------------------------------
# 口令留空：已装过则沿用 redis.conf 里的（load_existing_secrets 已读），首次则生成。真相在服务器上（写进交接文档），env 不必保存
[[ -n "${REDIS_PASS}" ]] || REDIS_PASS="$(openssl rand -hex 16)"
sed -i -E "s|^#? *bind .*|bind 127.0.0.1 -::1|; s|^#? *port .*|port ${REDIS_PORT}|; s|^#? *requirepass .*|requirepass ${REDIS_PASS}|" "${REDIS_CONF}"
grep -q "^requirepass " "${REDIS_CONF}" || echo "requirepass ${REDIS_PASS}" >> "${REDIS_CONF}"
# 内存上限：缺省无上限，缓存无限增长会挤死同机的 PG。REDIS_MAXMEMORY 留空 = 不限；打满淘汰谁由 REDIS_MAXMEMORY_POLICY 定
# （引擎不替消费项目拍板：项目在 Redis 里存无 TTL 的持久键时 allkeys-* 会静默淘汰它们，所以缺省 volatile-lru 只淘汰带 TTL 的键）
sed -i -E '/^maxmemory /d; /^maxmemory-policy /d' "${REDIS_CONF}"
if [[ -n "${DATA_ROOT}" ]]; then
    mkdir -p "${DATA_ROOT}/redis"; chown redis:redis "${DATA_ROOT}/redis"; chmod 750 "${DATA_ROOT}/redis"
    sed -i -E "s|^dir .*|dir ${DATA_ROOT}/redis|" "${REDIS_CONF}"
    # 发行版 unit 有 ProtectSystem / ReadWritePaths 沙箱，数据盘路径要显式放行
    mkdir -p /etc/systemd/system/redis-server.service.d
    printf '[Service]\nReadWritePaths=-%s/redis\n' "${DATA_ROOT}" > /etc/systemd/system/redis-server.service.d/pg-ops.conf
    systemctl daemon-reload
fi
if [[ -n "${REDIS_MAXMEMORY}" ]]; then
    printf 'maxmemory %s\nmaxmemory-policy %s\n' "${REDIS_MAXMEMORY}" "${REDIS_MAXMEMORY_POLICY}" >> "${REDIS_CONF}"
fi
systemctl enable --now redis-server >/dev/null 2>&1
systemctl restart redis-server
ok "Redis 监听 127.0.0.1:${REDIS_PORT}（requirepass 已设，maxmemory=${REDIS_MAXMEMORY:-不限}，maxmemory-policy=${REDIS_MAXMEMORY_POLICY}）"

# ---- 6. 探活（任何一项不通即失败退出，不给假绿）----------------------------------
pg_isready -h 127.0.0.1 -p 5432 >/dev/null || die "探活失败：5432 直连不可达"
ok "5432 直连可达"
PGPASSWORD="${PG_SUPER_PASS}" psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -qtAXc "SELECT 1" >/dev/null \
    || die "探活失败：postgres 以网络口令经 5432 登录失败（看 pg_hba.conf 的 127.0.0.1 行是否 scram-sha-256）"
ok "postgres 经 5432 网络口令登录成功（DB 工具走这条）"
PGPASSWORD="${PGB_AUTH_PASS}" psql -h 127.0.0.1 -p "${PGB_PORT}" -U pgbouncer -d postgres -qtAXc "SELECT 1" >/dev/null \
    || die "探活失败：经 PgBouncer ${PGB_PORT}（transaction）以 pgbouncer 角色登录 postgres 库失败（看 /var/log/postgresql/pgbouncer.log）"
ok "经 PgBouncer ${PGB_PORT}（transaction）登录成功（认证链 客户端→PgBouncer→PG 通）"
PGPASSWORD="${PGB_AUTH_PASS}" psql -h 127.0.0.1 -p "${PGB_SESSION_PORT}" -U pgbouncer -d postgres -qtAXc "SELECT 1" >/dev/null \
    || die "探活失败：经 PgBouncer ${PGB_SESSION_PORT}（session）登录失败（看 /var/log/postgresql/pgbouncer-session.log，systemctl status pgbouncer-session）"
ok "经 PgBouncer ${PGB_SESSION_PORT}（session）登录成功"
[[ "$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASS}" --no-auth-warning ping)" == "PONG" ]] || die "探活失败：Redis 未回 PONG"
ok "Redis PONG（dir=$(redis-cli -p "${REDIS_PORT}" -a "${REDIS_PASS}" --no-auth-warning config get dir | tail -1)）"

# ---- 6b. 自检（只报告，不影响装机结果）----
info "自检（只报告）：连接分类 + 每连接事务数"
if [[ -x "${PG_OPS_DIR}/bin/diag/pg-conn-audit.sh" ]]; then
    bash "${PG_OPS_DIR}/bin/diag/pg-conn-audit.sh" 5 || echo "[!] 自检脚本运行出错（不影响装机结果）"
else
    info "跳过自检：${PG_OPS_DIR}/bin/diag/pg-conn-audit.sh 不存在"
fi

# ---- 7. 交接文档（函数定义在前面，与 DOCS_ONLY 共用）----
write_handover

cat <<SUMMARY

=== 完成。开发机侧 ===
交接文档（服务器信息 / 口令 / 隧道 / 安全配置 / 运维）取回：bash <skill-dir>/scripts/pgops-fetch.sh ${SSH_TARGET} ${PG_OPS_DIR}/handover.md
隧道（四口一起）：
  ssh -N -L 5432:127.0.0.1:5432 -L ${PGB_PORT}:127.0.0.1:${PGB_PORT} -L ${PGB_SESSION_PORT}:127.0.0.1:${PGB_SESSION_PORT} -L ${REDIS_PORT}:127.0.0.1:${REDIS_PORT} ${SSH_TARGET}
应用与集成测试连 ${PGB_PORT}（transaction 池）；要会话级特性又想经池子的连 ${PGB_SESSION_PORT}（session 池）；pg_restore / 迁移工具 / DB 工具连 5432（直连）。
诊断脚本已装到 ${PG_OPS_DIR}/bin/diag/（用法见 sudo cat ${PG_OPS_DIR}/bin/diag/README.md）。
下一步：每个项目用 pg-dev-init 生成建库脚本（只需库名），建出的角色经 PgBouncer 自动可登录。
SUMMARY

#!/usr/bin/env bash
# pg-sync/scripts/lib.sh —— 生产侧与 dev 侧共用的守卫函数、只读会话、manifest 读写、sha256 校验。
# 生产侧：render.sh bundle 把本文件原样复制进 bundle 目录，prod/*.sh 用 `source lib.sh` 引用。
# dev 侧：render.sh dev 把本文件正文（去掉 shebang）内嵌进自包含脚本，dev/*.sh 直接使用同名函数。
# 本文件不单独执行，只被 source / 内嵌。

# ---- 三段式输出 --------------------------------------------------------------------
# die <problem> [cause] [fix] —— problem 必填；cause / fix 缺省则不打印该行。非零退出。
die() {
    local problem="${1:?die() 缺 problem 参数}" cause="${2:-}" fix="${3:-}"
    echo "problem: ${problem}" >&2
    [[ -n "${cause}" ]] && echo "cause: ${cause}" >&2
    [[ -n "${fix}" ]] && echo "fix: ${fix}" >&2
    exit 1
}
info() { echo "[*] $*"; }
ok()   { echo "[✓] $*"; }
ts()   { date '+%T'; }

# ---- 守卫 ---------------------------------------------------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "需要 root（sudo）" "" "sudo bash $0 ..."
}

# require_dev_marker —— 只允许在登记过的开发机（跑过 pg-dev-server 装机）且 PG_OPS_ROLE=dev 时继续
require_dev_marker() {
    [[ -f /opt/pg-ops/handover.md ]] || die \
        "未找到 /opt/pg-ops/handover.md" \
        "这台机没跑过 pg-dev-server 装机，不是登记过的开发机" \
        "先在这台机上跑 pg-dev-server 装机，或确认连的是正确的 dev 机"
    [[ "${PG_OPS_ROLE:-}" == "dev" ]] || die \
        "PG_OPS_ROLE 不是 dev（当前: ${PG_OPS_ROLE:-<空>}）" \
        "本脚本只允许在开发机执行" \
        "检查 pg-sync.env 里的 PG_OPS_ROLE"
}

# require_cmd <cmd> [fallback] —— 命令不存在时若给了 fallback 就回落（stderr 提示）并回显要用的命令名；
# 两者都没有则 die。用法：COMPRESS_CMD="$(require_cmd zstd gzip)"
require_cmd() {
    local cmd="${1:?require_cmd() 缺命令名参数}" fallback="${2:-}"
    if command -v "${cmd}" >/dev/null 2>&1; then
        echo "${cmd}"
        return 0
    fi
    if [[ -n "${fallback}" ]] && command -v "${fallback}" >/dev/null 2>&1; then
        echo "[*] 缺 ${cmd}，回落 ${fallback}" >&2
        echo "${fallback}"
        return 0
    fi
    die \
        "缺 ${cmd}$([[ -n "${fallback}" ]] && echo "（回落 ${fallback} 也没有）")" \
        "未安装对应命令" \
        "装上 ${cmd}$([[ -n "${fallback}" ]] && echo " 或 ${fallback}") 后重跑"
}

# ---- 只读会话 -----------------------------------------------------------------------
# psql_ro <db> [psql 参数...] —— session 级只读（default_transaction_read_only=on）+ 语句不超时
# 但排队上锁受 LOCK_WAIT_TIMEOUT 限制（缺省 30s）；以 postgres OS 用户 peer 登录。
psql_ro() {
    local db="${1:?psql_ro() 缺 db 参数}"; shift
    sudo -u postgres env PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=0 -c lock_timeout=${LOCK_WAIT_TIMEOUT:-30s} -c client_min_messages=warning" \
        psql -v ON_ERROR_STOP=1 -qtAX -d "${db}" "$@"
}

# probe_conn <db> —— `select 1` 探测能否以 postgres OS 用户 peer 登录 <db>；失败时区分三种原因给三段式
probe_conn() {
    local db="${1:?probe_conn() 缺 db 参数}" out
    if out="$(sudo -u postgres psql -v ON_ERROR_STOP=1 -qtAXc 'select 1' -d "${db}" 2>&1)"; then
        return 0
    fi
    case "${out}" in
        *"peer authentication failed"*)
            die "连不上 ${db}" "peer 认证被拒" \
                "确认以 postgres 用户执行本脚本，并核 pg_hba.conf 的 local all postgres peer 一行" ;;
        *"no pg_hba.conf entry"*)
            die "连不上 ${db}" "pg_hba.conf 没有匹配的条目" \
                "核 pg_hba.conf 是否有 local all postgres peer 一行" ;;
        *"database"*"does not exist"*)
            die "连不上 ${db}" "库不存在" "确认库名，或先跑 00-inventory 核对身份" ;;
        *)
            die "连不上 ${db}" "${out}" "按上面的错误信息排查（PostgreSQL 是否在跑 / 权限是否正确）" ;;
    esac
}

# ---- manifest.json 读写与校验 --------------------------------------------------------
# manifest_get <manifest.json> <字段路径>（如 .schema_sha256 或 .source.sysid）—— 优先 jq，缺则 python3
manifest_get() {
    local file="${1:?manifest_get() 缺 manifest 文件参数}" path="${2:?manifest_get() 缺字段路径参数}"
    [[ -r "${file}" ]] || die "读不到 ${file}"
    if command -v jq >/dev/null 2>&1; then
        jq -r "${path} // empty" "${file}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "${file}" "${path}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
cur = data
for part in sys.argv[2].lstrip('.').split('.'):
    if part == '':
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = None
        break
if cur is None:
    print('')
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur))
else:
    print(cur)
PYEOF
    else
        die "读 manifest 需要 jq 或 python3，两者都没有" "生产/dev 机缺工具" "apt-get install jq（或确认 python3 已装，Ubuntu 通常自带）"
    fi
}

# _manifest_files_tsv <manifest.json> —— 内部用：把 .files[] 展开成 path\tsha256\tbytes 三列
_manifest_files_tsv() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.files[]? | [.path, .sha256, (.bytes|tostring)] | @tsv' "${file}"
    else
        python3 - "${file}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
for f in (data.get('files') or []):
    print(f"{f.get('path', '')}\t{f.get('sha256', '')}\t{f.get('bytes', '')}")
PYEOF
    fi
}

# verify_manifest_files <manifest.json 所在目录> —— 校验 .files[] 里每个文件的 sha256 与字节数，
# 不符 / 缺文件都列出后 die；全部通过打印 ok。
verify_manifest_files() {
    local dir="${1:?verify_manifest_files() 缺目录参数}" manifest bad=0
    manifest="${dir}/manifest.json"
    [[ -r "${manifest}" ]] || die "读不到 ${manifest}"
    local path sha bytes f actual_bytes actual_sha
    while IFS=$'\t' read -r path sha bytes; do
        [[ -n "${path}" ]] || continue
        f="${dir}/${path}"
        if [[ ! -r "${f}" ]]; then
            echo "problem: 缺文件 ${path}" >&2
            bad=1
            continue
        fi
        actual_bytes="$(wc -c < "${f}" | tr -d ' ')"
        actual_sha="$(sha256sum "${f}" | awk '{print $1}')"
        if [[ "${actual_bytes}" != "${bytes}" || "${actual_sha}" != "${sha}" ]]; then
            echo "problem: ${path} 校验不符（期望 ${bytes} 字节 / sha256 ${sha}；实际 ${actual_bytes} 字节 / sha256 ${actual_sha}）" >&2
            bad=1
        fi
    done < <(_manifest_files_tsv "${manifest}")
    [[ "${bad}" -eq 0 ]] || die \
        "文件校验失败" \
        "传输截断或被篡改" \
        "重跑传输步骤（rsync / ossutil 都支持增量续传，只需重传坏文件）"
    ok "全部文件 sha256 与字节数校验通过"
}

# ---- 杂项 ---------------------------------------------------------------------------
# new_sync_id <db> —— 生成本次同步的 sync_id：<db>-<YYYYmmdd-HHMMSS>
new_sync_id() {
    local db="${1:?new_sync_id() 缺 db 参数}"
    echo "${db}-$(date '+%Y%m%d-%H%M%S')"
}

# log_tee <日志文件> —— 之后全部 stdout/stderr 同时追加写入该文件（终端仍能看到）
log_tee() {
    local log="${1:?log_tee() 缺日志文件参数}"
    mkdir -p "$(dirname "${log}")"
    exec > >(tee -a "${log}") 2>&1
}

# trap_cleanup <待清理路径> —— 中断（INT/TERM）时删除本次未完成的产物目录，供原地重跑
trap_cleanup() {
    local target="${1:?trap_cleanup() 缺路径参数}"
    # [impl-review-fix] F5：清理后必须 exit，否则脚本在 trap 处理完后继续往下跑
    # shellcheck disable=SC2064
    trap "echo 'problem: 被中断，清理 ${target}' >&2; rm -rf '${target}'; exit 1" INT TERM
}

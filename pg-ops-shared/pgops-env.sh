#!/usr/bin/env bash
# pgops-env.sh —— 读 / 写 / 展示 pg-ops 的 env 文件（含口令），口令值不进模型上下文（ADR-0002）。
#
# 用法：
#   pgops-env.sh get   <env 文件> KEY                 —— 打印该键的值（无则空），KEY 含 PASS 拒绝
#   pgops-env.sh set   <env 文件> [--from <example>] KEY=VAL [KEY=VAL ...]
#   pgops-env.sh show  <文件>                          —— 打印参数段，*PASS= 的值打星
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/pgops-lib.sh"

cmd_get() {
    local file="${1:?用法: pgops-env.sh get <env 文件> KEY}"
    local key="${2:?用法: pgops-env.sh get <env 文件> KEY}"
    case "${key}" in
        *PASS*) die "拒绝回显口令键 ${key}" "口令不进模型上下文（ADR-0002）" "看打星参数段用 pgops-env.sh show <文件>" 2 ;;
    esac
    [[ -r "${file}" ]] || die "读不到 ${file}"
    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        die "非法键名 ${key}" "键名只允许 [A-Za-z_][A-Za-z0-9_]*" "检查调用方传入的键名"
    fi
    (
        # shellcheck disable=SC1090
        source "${file}"
        printf '%s\n' "${!key-}"
    )
}

cmd_set() {
    local file="${1:?用法: pgops-env.sh set <env 文件> [--from <example>] KEY=VAL ...}"
    shift
    local from=""
    if [[ "${1:-}" == "--from" ]]; then
        from="${2:?--from 需要一个参数}"
        shift 2
    fi

    if [[ ! -e "${file}" ]]; then
        if [[ -z "${from}" ]]; then
            die "env 不存在" "首次落 env 要以 example 为底" "加 --from <skill-dir>/<skill>.env.example"
        fi
        [[ -r "${from}" ]] || die "读不到 --from 文件 ${from}"
        mkdir -p "$(dirname "${file}")"
        ( umask 077; cp "${from}" "${file}" )
    fi

    [[ $# -ge 1 ]] || die "至少需要一个 KEY=VAL"

    local kv key val esc_val newline tmp dir
    for kv in "$@"; do
        case "${kv}" in
            *=*) : ;;
            *) echo "problem: 拒绝写入 ${kv}（不是 KEY=VAL 形式）" >&2; exit 1 ;;
        esac
        key="${kv%%=*}"
        val="${kv#*=}"
        if [[ ! "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            die "拒绝写入 ${key}=…（键名非法）" "键名只允许 [A-Z_][A-Z0-9_]*，值不能含换行" "改键名 / 去掉换行"
        fi
        case "${val}" in
            *$'\n'*) die "拒绝写入 ${key}=…（值含换行）" "键名只允许 [A-Z_][A-Z0-9_]*，值不能含换行" "改键名 / 去掉换行" ;;
        esac

        esc_val=${val//\'/\'\\\'\'}
        newline="${key}='${esc_val}'"

        dir="$(dirname "${file}")"
        tmp="$(mktemp "${dir}/.pgops-env.XXXXXX")"
        if grep -q "^${key}=" "${file}" 2>/dev/null; then
            awk -v k="${key}" -v nl="${newline}" '
                index($0, k"=") == 1 { print nl; next }
                { print }
            ' "${file}" > "${tmp}"
        else
            cp "${file}" "${tmp}"
            printf '%s\n' "${newline}" >> "${tmp}"
        fi
        mv "${tmp}" "${file}"
    done

    echo "已写入 ${file}"
}

cmd_show() {
    local file="${1:?用法: pgops-env.sh show <文件>}"
    [[ -r "${file}" ]] || die "读不到 ${file}"
    grep -E '^[A-Z_]+=' "${file}" | while IFS= read -r line; do
        key="${line%%=*}"
        case "${key}" in
            *PASS*) printf '%s=***\n' "${key}" ;;
            *) printf '%s\n' "${line}" ;;
        esac
    done
}

sub="${1:-}"
[[ -n "${sub}" ]] || die "用法: pgops-env.sh get|set|show ..."
shift
case "${sub}" in
    get)  cmd_get "$@" ;;
    set)  cmd_set "$@" ;;
    show) cmd_show "$@" ;;
    *) die "未知子命令 ${sub}（只支持 get/set/show）" ;;
esac

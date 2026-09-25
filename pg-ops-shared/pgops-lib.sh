#!/usr/bin/env bash
# pgops-lib.sh —— pg-ops-shared/ 下脚本的公共函数。source 后使用，不独立执行。

# die <problem> [cause] [fix] [exit_code=1]
die() {
    local problem="${1:?}" cause="${2:-}" fix="${3:-}" code="${4:-1}"
    echo "problem: ${problem}" >&2
    [[ -n "${cause}" ]] && echo "cause: ${cause}" >&2
    [[ -n "${fix}" ]] && echo "fix: ${fix}" >&2
    exit "${code}"
}

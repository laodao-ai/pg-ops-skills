#!/usr/bin/env bash
# pgops-guard.sh —— 幂等确保消费仓的 .gitignore / .claudeignore / .claude/settings.json
# 都挡住了 .pg-ops/（含口令的 env 与交接文档只落在这里，ADR-0002）。
# 用法：pgops-guard.sh <项目根>
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/pgops-lib.sh"

ROOT="${1:?用法: pgops-guard.sh <项目根>}"
cd "${ROOT}"

DENY_ENTRY='Read(./.pg-ops/**)'

# ---- .gitignore ----
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -f .gitignore ]] && grep -qxF '.pg-ops/' .gitignore; then
        echo ".gitignore: 已有，跳过"
    else
        echo '.pg-ops/' >> .gitignore
        echo ".gitignore: 已加"
    fi
else
    echo ".gitignore: 跳过（不是 git 仓）"
fi

# ---- .claudeignore ----
if [[ -f .claudeignore ]] && grep -qxF '.pg-ops/' .claudeignore; then
    echo ".claudeignore: 已有，跳过"
else
    printf '%s\n' '.pg-ops/' >> .claudeignore
    echo ".claudeignore: 已加"
fi

# ---- .claude/settings.json ----
mkdir -p .claude
SETTINGS=".claude/settings.json"

if ! command -v python3 >/dev/null 2>&1; then
    die "settings.json 跳过（无 python3，其余两项已做）" "本机无 python3" "装 python3 重跑，或人工加 ${DENY_ENTRY} 到 permissions.deny"
fi

python3 - "${SETTINGS}" "${DENY_ENTRY}" <<'PYEOF'
import json
import os
import sys

path, deny_entry = sys.argv[1], sys.argv[2]

if not os.path.exists(path):
    data = {"permissions": {"deny": [deny_entry]}}
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("settings.json: 已加")
    sys.exit(0)

with open(path) as f:
    raw = f.read()

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("problem: settings.json 解析失败，未改动", file=sys.stderr)
    print("cause: 文件不是合法 JSON", file=sys.stderr)
    print("fix: 人工修好 JSON 后重跑", file=sys.stderr)
    sys.exit(1)

permissions = data.setdefault("permissions", {})
deny = permissions.setdefault("deny", [])

if deny_entry in deny:
    print("settings.json: 已有，跳过")
else:
    deny.append(deny_entry)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("settings.json: 已加")
PYEOF

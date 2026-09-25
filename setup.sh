#!/usr/bin/env bash
# pg-ops setup — install skills into BOTH global hosts:
#   - Claude  ~/.claude/skills/
#   - Codex   ~/.codex/skills/
#
# Idempotent. Unix: symlink (git pull auto-reflects). Windows(Git Bash): copy +
# marker — MSYS `ln -s` silently degrades to a copy that `git pull` won't
# refresh, so on Windows we copy explicitly and stamp a `.pg-ops` marker
# (holding the installed HEAD sha) for ownership + versioning; update = re-run.
# Windows 下仓内 `pg-ops-shared/`（诊断脚本 + 口令工具的唯一落点）走与四个 skill 目录相同的
# 独占安装语义（自属整份替换 / 非自属拒装），每个宿主先装它再装四个 skill；Unix 不装它，
# 软链天然经物理路径解回仓内。
#
# Conflict policy:
#   - target already a symlink pointing at the same path we'd install -> success,
#     no-op (idempotent re-run).
#   - target exists as a real directory, or a symlink pointing elsewhere, or a
#     regular file -> fail loud with a migration command. MUST NOT overwrite or
#     recursively delete anything we don't own.
#   - Windows: any symlink at the target (valid or dangling) is refused outright
#     — copy mode does not adopt symlinks, ownership is judged by the `.pg-ops`
#     marker on a real directory only.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIRS=("$HOME/.claude/skills" "$HOME/.codex/skills")

# 平台探测：Git Bash / MSYS / Cygwin 一律走 Windows 拷贝分支。
IS_WINDOWS=0
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) IS_WINDOWS=1 ;;
esac
MARKER=".pg-ops"                             # Windows 拷贝的所有权标记（内含安装版本 sha）
is_our_copy() {                              # 一份拷贝是不是本脚本装的
    [[ -f "$1/${MARKER}" ]]
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; }

install_skill() {
    local skill_name="$1" dest_dir="$2"
    local src="${REPO_DIR}/${skill_name}"
    local target="${dest_dir}/${skill_name}"

    mkdir -p "${dest_dir}"

    if [[ "${IS_WINDOWS}" -eq 1 ]]; then
        # Windows(Git Bash): 拷贝 + marker。只覆盖本脚本自己装的拷贝，绝不动别人的目录。
        if [[ -L "${target}" ]]; then
            # 软链一律拒装（不跟随判所有权），有效软链、悬空软链都在此拦下；软链与被指向目录都不动。
            fail "problem: ${target} 是软链（Windows 拷贝模式不接管软链）"
            fail "cause: 该路径被非本脚本管理的内容占用，拒绝覆盖"
            fail "fix: 确认内容后手动迁移，例如 mv '${target}' '${target}.bak'，再重跑本脚本"
            exit 1
        fi
        if [[ -e "${target}" ]] && ! is_our_copy "${target}"; then
            fail "problem: ${target} 已存在（非本脚本管理的目录/普通文件）"
            fail "cause: 该路径被非本脚本安装的内容占用，拒绝覆盖"
            fail "fix: 确认内容后手动迁移，例如 mv '${target}' '${target}.bak'，再重跑本脚本"
            exit 1
        fi
        rm -rf "${target}"                    # 自属旧拷贝（或不存在）→ 清掉重拷，保幂等更新；旧标记随目录一起被换掉
        cp -r "${src}" "${target}"
        git -C "${REPO_DIR}" rev-parse HEAD > "${target}/${MARKER}" 2>/dev/null \
            || echo unknown > "${target}/${MARKER}"
        pass "${skill_name} @ ${dest_dir} — 已安装拷贝（Windows），更新请重跑 setup.sh"
        return 0
    fi

    if [[ -L "${target}" ]]; then
        local existing_link
        existing_link="$(readlink "${target}")"
        if [[ "${existing_link}" == "${src}" ]]; then
            pass "${skill_name} @ ${dest_dir} — 已是正确软链，跳过"
            return 0
        fi
        fail "problem: ${target} 是软链，但指向别处（${existing_link}）"
        fail "cause: 目标已被另一份安装占用（另一个仓 / 另一次手工链接）"
        fail "fix: 确认无误后手动执行 rm '${target}' && ln -s '${src}' '${target}'，或重新运行本脚本前先清理"
        exit 1
    fi

    if [[ -e "${target}" ]]; then
        fail "problem: ${target} 已存在（目录或普通文件，非软链）"
        fail "cause: 该路径被非本脚本管理的内容占用，拒绝覆盖"
        fail "fix: 确认内容后手动迁移，例如 mv '${target}' '${target}.bak' && ln -s '${src}' '${target}'"
        exit 1
    fi

    ln -s "${src}" "${target}"
    pass "${skill_name} @ ${dest_dir} — 已安装软链 → ${src}"
}

info "=== pg-ops setup ==="
for dest in "${TARGET_DIRS[@]}"; do
    if [[ "${IS_WINDOWS}" -eq 1 ]]; then
        # pg-ops-shared 先于四个 skill 安装：冲突在任何 rm -rf 之前 fail，本宿主已有的 skill
        # 拷贝不受影响。与 skill 目录同一套独占安装语义（自属整份替换 / 非自属拒装）。
        install_skill "pg-ops-shared" "${dest}"
    fi
    install_skill "pg-dev-server" "${dest}"
    install_skill "pg-dev-init" "${dest}"
    install_skill "pg-sync" "${dest}"
    install_skill "pg-ops-upgrade" "${dest}"
    # 规划中的 skill（未实现前不安装）：pg-backup · pg-monitor · pg-roles
    if [[ "${IS_WINDOWS}" -eq 1 ]] && [[ -f "${dest}/shared/${MARKER}" ]]; then
        # 旧版本在 <dest>/shared 留下的安装残留：本仓不再读写它，只提示、不删不改。
        info "${dest}/shared 是旧安装残留，确认其中无他仓仍在使用的文件后可手动删除"
    fi
done
if [[ "${IS_WINDOWS}" -eq 1 ]]; then
    info "mode: copy (Windows) —— 更新请重跑本脚本（git pull 不会自动反映）"
else
    info "mode: symlink (Unix) —— git pull 自动反映最新"
fi
pass "全部完成"

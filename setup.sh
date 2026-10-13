#!/usr/bin/env bash
# pg-ops setup — install skills into BOTH global hosts:
#   - Claude           ~/.claude/skills/
#   - Codex / Cursor   ~/.agents/skills/
#
# Idempotent. Unix: symlink (git pull auto-reflects). Windows(Git Bash): copy +
# marker — MSYS `ln -s` silently degrades to a copy that `git pull` won't
# refresh, so on Windows we copy explicitly and stamp a `.pg-ops` marker
# (holding the installed HEAD sha) for ownership + versioning; update = re-run.
# Windows 下仓内 `pg-ops-shared/`（诊断脚本 + 口令工具的唯一落点）走与四个 skill 目录相同的
# 独占安装语义（自属整份替换 / 非自属拒装），每个宿主先装它再装四个 skill；Unix 不装它，
# 软链天然经物理路径解回仓内。
#
# 旧宿主 `~/.codex/skills/`：新落点装妥本仓自属项后，清理其中指向本仓 / 带 `.pg-ops` 的旧项；
# 第三方占用不动。
#
# Conflict policy:
#   - Unix: target already a symlink pointing at the same path we'd install ->
#     success, no-op. Foreign symlink / non-empty real dir / file -> fail loud.
#     Empty directory is takeable (Windows accident leftovers).
#   - Windows: copy via transactional rename (stage → aside → swap). Never
#     rm -rf the live target first — a locked cwd leaves an unmarked empty dir.
#     Foreign / symlink / busy target -> SKIP that skill and continue (exit 0).
#     Empty directory is takeable. Ownership = `.pg-ops` marker on a real dir.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills")
# 曾装进旧 Codex 宿主、迁移期需要回收的名字（含 Windows 独占的 pg-ops-shared）。
LEGACY_CODEX_NAMES=(pg-dev-server pg-dev-init pg-sync pg-ops-upgrade pg-ops-shared)

# 平台探测：Git Bash / MSYS / Cygwin 一律走 Windows 拷贝分支。
IS_WINDOWS=0
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) IS_WINDOWS=1 ;;
esac
MARKER=".pg-ops"                             # Windows 拷贝的所有权标记（内含安装版本 sha）
is_our_copy() {                              # 一份拷贝是不是本脚本装的
    [[ -f "$1/${MARKER}" ]]
}
# Empty dir has nothing to lose — takeable (Windows accident leftovers).
is_empty_dir() {
    [[ -d "$1" ]] && [[ ! -L "$1" ]] && [[ -z "$(ls -A "$1" 2>/dev/null)" ]]
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[SKIP]${NC} $1"; }

# Rename when destination path must not already exist as a directory.
# Prefer GNU `mv -T` (Windows Git Bash); fall back to plain `mv` (BSD/macOS).
_mv_noslash() {
    if [[ -z "${_PG_OPS_MV_T:-}" ]]; then
        local probe
        probe="$(mktemp -d "${TMPDIR:-/tmp}/pg-ops-mvprobe.XXXXXX")" || return 1
        if mv -T "$probe" "${probe}.dst" 2>/dev/null; then
            _PG_OPS_MV_T=1
            rmdir "${probe}.dst" 2>/dev/null || true
        else
            _PG_OPS_MV_T=0
            rmdir "$probe" 2>/dev/null || true
        fi
    fi
    if [[ "${_PG_OPS_MV_T}" -eq 1 ]]; then
        mv -T -- "$@"
    else
        mv -- "$@"
    fi
}

# Windows: recover interrupted transaction (target missing + our backup).
recover_windows_skill_backup() {  # $1=target $2=skill name
    local target="$1" name="$2" transaction owner
    for transaction in "${target%/*}/.pg-ops-${name}."*; do
        [[ -d "$transaction" && ! -L "$transaction" ]] || continue
        [[ -f "$transaction/owner" && ! -L "$transaction/owner" ]] || continue
        IFS= read -r owner < "$transaction/owner" || continue
        [[ "$owner" == "$name" ]] || continue
        if [[ -d "$transaction/backup" && ! -L "$transaction/backup" ]]; then
            [[ -f "$transaction/backup/${MARKER}" ]] || continue
            if [[ ! -e "$target" && ! -L "$target" ]]; then
                _mv_noslash "$transaction/backup" "$target" 2>/dev/null || return 1
            else
                continue
            fi
        else
            continue
        fi
        rm -rf -- "$transaction" 2>/dev/null || return 1
    done
}

# Windows: stage → rename-aside → swap. Failures keep the old install; do not abort the run.
install_windows_skill() {  # $1=src $2=target $3=skill name
    local source="$1" target="$2" name="$3" transaction sha
    if [[ -L "$target" ]]; then
        warn "${name} @ ${target%/*} — 是软链，Windows 拷贝模式不接管（关闭占用后迁移或删软链再重跑）"
        return 0
    fi
    if [[ -e "$target" ]]; then
        if [[ ! -d "$target" ]]; then
            warn "${name} @ ${target%/*} — 路径已存在且非目录，未覆盖"
            return 0
        fi
        if ! is_our_copy "$target" && ! is_empty_dir "$target"; then
            warn "${name} @ ${target%/*} — 非本脚本管理，未覆盖（手动 mv 到 .bak 后重跑）"
            return 0
        fi
    fi
    if ! recover_windows_skill_backup "$target" "$name"; then
        warn "${name} @ ${target%/*} — backup 恢复失败，跳过"
        return 0
    fi
    sha="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    transaction="$(mktemp -d "${target%/*}/.pg-ops-${name}.XXXXXX")" || {
        warn "${name} @ ${target%/*} — staging 创建失败"; return 0
    }
    if ! printf '%s\n' "$name" > "$transaction/owner" ||
       ! mkdir "$transaction/stage" ||
       ! cp -R "$source/." "$transaction/stage" ||
       ! printf '%s\n' "$sha" > "$transaction/stage/${MARKER}"; then
        rm -rf -- "$transaction" || true
        warn "${name} @ ${target%/*} — staging 失败，旧安装保留"
        return 0
    fi
    if [[ -d "$target" ]] && ! _mv_noslash "$target" "$transaction/backup" 2>/dev/null; then
        rm -rf -- "$transaction" || true
        warn "${name} @ ${target%/*} — 目录被占用（关闭工作目录在该目录下的终端/编辑器后重跑），旧安装保留"
        return 0
    fi
    if ! _mv_noslash "$transaction/stage" "$target" 2>/dev/null; then
        if [[ -d "$transaction/backup" ]]; then
            if ! _mv_noslash "$transaction/backup" "$target" 2>/dev/null; then
                warn "${name} @ ${target%/*} — swap/rollback 失败，backup 保留于 $transaction"
                return 0
            fi
        fi
        rm -rf -- "$transaction" || true
        warn "${name} @ ${target%/*} — swap 失败，旧安装已恢复"
        return 0
    fi
    rm -rf -- "$transaction" || true
    pass "${name} @ ${target%/*} — 已安装拷贝（Windows），更新请重跑 setup.sh"
}

install_skill() {
    local skill_name="$1" dest_dir="$2"
    local src="${REPO_DIR}/${skill_name}"
    local target="${dest_dir}/${skill_name}"

    mkdir -p "${dest_dir}"

    if [[ "${IS_WINDOWS}" -eq 1 ]]; then
        install_windows_skill "${src}" "${target}" "${skill_name}"
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
        if is_empty_dir "${target}"; then
            rmdir "${target}" 2>/dev/null || rm -rf "${target}"
        else
            fail "problem: ${target} 已存在（目录或普通文件，非软链）"
            fail "cause: 该路径被非本脚本管理的内容占用，拒绝覆盖"
            fail "fix: 确认内容后手动迁移，例如 mv '${target}' '${target}.bak' && ln -s '${src}' '${target}'"
            exit 1
        fi
    fi

    ln -s "${src}" "${target}"
    pass "${skill_name} @ ${dest_dir} — 已安装软链 → ${src}"
}

# 先确认 ~/.agents/skills 已有本仓版本，再清理 ~/.codex/skills 自属旧项；同名第三方不动。
cleanup_legacy_codex_skills() {
    local old="$HOME/.codex/skills"
    local new="$HOME/.agents/skills"
    local name entry link_dest

    [[ -d "${old}" ]] || return 0

    for name in "${LEGACY_CODEX_NAMES[@]}"; do
        entry="${old}/${name}"
        [[ -e "${entry}" || -L "${entry}" ]] || continue

        if [[ -L "${new}/${name}" ]]; then
            [[ "$(readlink "${new}/${name}")" == "${REPO_DIR}/${name}" ]] || continue
        elif is_our_copy "${new}/${name}"; then
            :
        else
            continue
        fi

        if [[ -L "${entry}" ]]; then
            link_dest="$(readlink "${entry}")"
            [[ "${link_dest}" == "${REPO_DIR}/${name}" ]] || continue
        elif is_our_copy "${entry}"; then
            :
        else
            continue
        fi

        rm -rf "${entry}"
        info "${name} @ ${old} — 已迁移到 ${new}"
    done
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
cleanup_legacy_codex_skills
if [[ "${IS_WINDOWS}" -eq 1 ]]; then
    info "mode: copy (Windows) —— 更新请重跑本脚本（git pull 不会自动反映）"
else
    info "mode: symlink (Unix) —— git pull 自动反映最新"
fi
pass "全部完成"

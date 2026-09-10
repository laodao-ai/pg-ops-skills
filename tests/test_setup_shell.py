"""Offline tests for setup.sh's install list and ownership policy.

setup.sh installs the ops-line skills (3) plus the upgrade skill
(pg-ops-upgrade) into both global hosts. It only ever touches what it owns:
a symlink it would install itself (idempotent no-op), or — on Windows — a
copy carrying its own `.pg-ops` marker. Anything else is a fail-loud with a
problem/cause/fix triple; it MUST NOT overwrite or recursively delete a
directory it does not own.

No real ~/.claude or ~/.codex touched: every test runs setup.sh with HOME
pointed at a throwaway tmp_path (TARGET_DIRS is derived from $HOME, no
override variable). The Windows branch is exercised by shadowing `uname` on
PATH with a fake binary that reports a Windows-shaped uname -s string
(MINGW64_NT-...), the same mocking pattern this repo uses elsewhere.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SETUP_SH = REPO_ROOT / "setup.sh"

# 4 个 skill，顺序与 setup.sh 安装循环一致（运维线 3 + upgrade 1）。
NEW_SKILLS = [
    "pg-dev-server",
    "pg-dev-init",
    "pg-sync",
    "pg-ops-upgrade",
]
MARKER = ".pg-ops"  # 与 setup.sh 的 MARKER 常量一致（Windows 拷贝的所有权标记）
HOSTS = [".claude/skills", ".codex/skills"]


def _write_exec(path: Path, body: str) -> Path:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


def _fake_windows_uname(tmp_path: Path) -> str:
    bin_dir = tmp_path / "fake-bin"
    bin_dir.mkdir()
    _write_exec(bin_dir / "uname", "#!/bin/bash\necho 'MINGW64_NT-10.0'\n")
    return str(bin_dir)


def _run_setup(home: Path, extra_path: str | None = None, stdin_data: str | None = None):
    env = dict(os.environ)
    env["HOME"] = str(home)
    if extra_path:
        env["PATH"] = f"{extra_path}:{env['PATH']}"
    kwargs = dict(cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=30)
    if stdin_data is not None:
        return subprocess.run(["bash", str(SETUP_SH)], input=stdin_data, **kwargs)
    # No stdin at all -> inherits a real (non-tty in test harness) stdin.
    return subprocess.run(
        ["bash", str(SETUP_SH)], stdin=subprocess.DEVNULL, **kwargs
    )


class TestSkillsLinkedUnix:
    """① 四个 skill 在两个宿主目录下都建成指向本仓的软链。"""

    def test_symlinks_created_for_every_skill_in_both_hosts(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()

        result = _run_setup(home)
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            dest = home / host
            for skill in NEW_SKILLS:
                target = dest / skill
                assert target.is_symlink(), f"{target} should be a symlink"
                assert os.readlink(target) == str(REPO_ROOT / skill)


class TestForeignSymlinkFailsLoud:
    """② 同名 symlink 指向别处 ⇒ fail-loud 三行，绝不改链别人的安装。"""

    def test_symlink_to_another_repo_fails_loud_and_is_untouched(self, tmp_path: Path):
        home = tmp_path / "home"
        other_repo = tmp_path / "other-repo" / "pg-dev-server"
        other_repo.mkdir(parents=True)
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        (dest / "pg-dev-server").symlink_to(other_repo)

        result = _run_setup(home)

        assert result.returncode != 0
        fail_lines = [line for line in result.stderr.splitlines() if "[FAIL]" in line]
        assert len(fail_lines) == 3, f"expected exactly 3 [FAIL] lines, got: {fail_lines}"
        assert "problem:" in result.stderr
        assert "cause:" in result.stderr
        assert "fix:" in result.stderr
        link = dest / "pg-dev-server"
        assert link.is_symlink()
        assert os.readlink(link) == str(other_repo)


class TestIdempotentRerun:
    """③ 幂等重跑 — running twice in a row is a clean no-op the second time."""

    def test_second_run_is_a_no_op_success(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()

        first = _run_setup(home)
        assert first.returncode == 0, first.stderr

        second = _run_setup(home)
        assert second.returncode == 0, second.stderr
        assert "全部完成" in second.stdout
        assert "已是正确软链，跳过" in second.stdout
        for host in HOSTS:
            dest = home / host
            for skill in NEW_SKILLS:
                target = dest / skill
                assert target.is_symlink()
                assert os.readlink(target) == str(REPO_ROOT / skill)


class TestForeignRealDirectoryFailLoud:
    """④ 非自属实体目录 fail-loud 三行文案（INST-6）—— problem / cause / fix，退出非 0，
    绝不覆盖或递归删除不认识的目录。
    """

    def test_real_directory_not_owned_fails_loud_with_three_lines(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        foreign_dir = dest / "pg-dev-server"
        foreign_dir.mkdir()
        (foreign_dir / "some-unrelated-file.txt").write_text("not ours\n")

        result = _run_setup(home)

        assert result.returncode != 0
        assert "problem:" in result.stderr
        assert "cause:" in result.stderr
        assert "fix:" in result.stderr
        fail_lines = [line for line in result.stderr.splitlines() if "[FAIL]" in line]
        assert len(fail_lines) == 3, f"expected exactly 3 [FAIL] lines, got: {fail_lines}"
        # 目录本身没被动过（不覆盖 / 不删）
        assert (foreign_dir / "some-unrelated-file.txt").exists()


class TestWindowsUnmarkedDirectoryFailsLoud:
    """⑤ Windows 分支：没有本脚本 marker 的同名目录 ⇒ fail-loud，不 rm -rf。"""

    def test_directory_without_marker_is_not_overwritten(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        foreign_dir = dest / "pg-dev-server"
        foreign_dir.mkdir()
        (foreign_dir / "not-ours.txt").write_text("someone else's copy\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")

        assert result.returncode != 0
        assert (foreign_dir / "not-ours.txt").exists()
        assert not (foreign_dir / MARKER).exists()


class TestWindowsOwnCopyRecopied:
    """⑥ Windows 自属拷贝（带 marker）重跑 ⇒ rm -rf 整份重拷，陈旧文件消失、marker 刷新。

    `shared/` 走的是不同分支（合并拷贝，非整份替换）——单独在用例 ⑦ 覆盖。
    """

    def test_marked_copy_is_recopied_fresh(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        for host in HOSTS:
            dest = home / host
            dest.mkdir(parents=True)
            copy_dir = dest / "pg-dev-server"
            copy_dir.mkdir()
            (copy_dir / MARKER).write_text("deadbeef\n")
            (copy_dir / "stale-file.txt").write_text("from the old copy\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            copy_dir = home / host / "pg-dev-server"
            assert copy_dir.is_dir()
            assert (copy_dir / MARKER).exists(), f"{copy_dir} should carry the marker"
            assert (copy_dir / MARKER).read_text().strip() != "deadbeef", (
                "marker should hold the freshly installed HEAD sha"
            )
            assert not (copy_dir / "stale-file.txt").exists(), (
                f"{copy_dir} should have been rm -rf'd and recopied fresh, not merged"
            )
            assert (copy_dir / "SKILL.md").exists()


class TestWindowsSharedMergeCopied:
    """⑦ Windows `shared/` 合并拷贝 —— 与 skill 目录的整份替换不同：`<dest>/shared` 是
    所有 skill 套件共用的落点，别的套件已拷入的文件必须原样保留，本仓的文件只补 / 覆盖。
    """

    def test_existing_foreign_file_in_shared_survives_merge_copy(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        for host in HOSTS:
            dest = home / host
            dest.mkdir(parents=True)
            shared_dir = dest / "shared"
            shared_dir.mkdir()
            # 模拟另一套 skill 的 setup.sh 先装过、往共用 shared/ 里拷了自己的脚本。
            (shared_dir / "other-suite-script.sh").write_text("# another suite's script\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            shared_dir = home / host / "shared"
            assert shared_dir.is_dir()
            # 别人已拷入的文件原样保留（合并拷贝，不是整份替换）。
            assert (shared_dir / "other-suite-script.sh").read_text() == "# another suite's script\n"
            # 本仓的 shared/ 脚本也被拷了进来。
            assert (shared_dir / "pgops-env.sh").exists()
            assert (shared_dir / "pgops-fetch.sh").exists()
            assert (shared_dir / "pgops-guard.sh").exists()
            assert (shared_dir / "diag").is_dir()

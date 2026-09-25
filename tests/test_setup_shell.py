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

    旧 `shared/`（他仓残留）不再合并拷贝，原样不动——单独在用例 ⑦
    （`TestForeignLegacySharedUntouched`）覆盖。
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


class TestWindowsFreshInstallPgOpsShared:
    """3.2 Windows 全新安装：`pg-ops-shared/` 与四个 skill 一起独占安装（不再是合并拷贝），
    且经安装副本真跑 `render.sh` 与一个 shim，证明 `../../pg-ops-shared` 在拷贝布局下真可达。
    """

    def test_fresh_install_has_pg_ops_shared_and_no_shared(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            dest = home / host
            shared_dir = dest / "pg-ops-shared"
            assert shared_dir.is_dir()
            assert (shared_dir / MARKER).exists()
            assert (shared_dir / "pgops-env.sh").exists()
            assert (shared_dir / "pgops-fetch.sh").exists()
            assert (shared_dir / "pgops-guard.sh").exists()
            assert (shared_dir / "diag").is_dir()
            assert not (dest / "shared").exists()

    def test_installed_copy_render_and_shim_reach_pg_ops_shared(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        dest = home / HOSTS[0]
        render_sh = dest / "pg-dev-server" / "scripts" / "render.sh"
        env_example = REPO_ROOT / "pg-dev-server" / "pg-dev-server.env.example"
        out = tmp_path / "rendered.sh"
        render_result = subprocess.run(
            ["bash", str(render_sh), str(env_example), str(out)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert render_result.returncode == 0, render_result.stderr
        assert "PG_OPS_DIAG_TGZ_B64" in out.read_text()

        show_target = tmp_path / "show-me.env"
        show_target.write_text("FOO=bar\n")
        shim = dest / "pg-dev-init" / "scripts" / "pgops-env.sh"
        shim_result = subprocess.run(
            ["bash", str(shim), "show", str(show_target)],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert shim_result.returncode == 0, shim_result.stderr


class TestForeignLegacySharedUntouched:
    """3.3（改写用例⑦）：宿主已有他仓 `shared/`（含他仓文件与他仓标记，无本仓标记）——本仓
    不再合并拷贝，`shared/` 原样不动，本仓的文件只出现在独占的 `pg-ops-shared/`。
    """

    def test_foreign_shared_untouched_and_our_files_go_to_pg_ops_shared(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        for host in HOSTS:
            dest = home / host
            dest.mkdir(parents=True)
            shared_dir = dest / "shared"
            shared_dir.mkdir()
            (shared_dir / "other-suite-script.sh").write_text("# another suite's script\n")
            (shared_dir / ".other-suite").write_text("marker\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            dest = home / host
            shared_dir = dest / "shared"
            assert sorted(p.name for p in shared_dir.iterdir()) == [
                ".other-suite",
                "other-suite-script.sh",
            ]
            assert (shared_dir / "other-suite-script.sh").read_text() == "# another suite's script\n"
            assert not (shared_dir / MARKER).exists()
            assert (dest / "pg-ops-shared" / "pgops-env.sh").exists()


class TestOwnPgOpsSharedReplaced:
    """3.4 自属旧 `pg-ops-shared/`（旧标记 + 一个仓内已不存在的 `stale.sh`）⇒ 整份替换：
    `stale.sh` 消失，标记刷新到当前 HEAD sha。
    """

    def test_own_pg_ops_shared_recopied_fresh(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        for host in HOSTS:
            dest = home / host
            dest.mkdir(parents=True)
            shared_dir = dest / "pg-ops-shared"
            shared_dir.mkdir()
            (shared_dir / MARKER).write_text("deadbeef\n")
            (shared_dir / "stale.sh").write_text("# no longer in the repo\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            shared_dir = home / host / "pg-ops-shared"
            assert not (shared_dir / "stale.sh").exists()
            assert (shared_dir / MARKER).read_text().strip() != "deadbeef"
            assert (shared_dir / "pgops-env.sh").exists()
            assert (shared_dir / "diag").is_dir()


class TestForeignPgOpsSharedRefused:
    """3.5 非自属 `pg-ops-shared/`（无标记 + `not-ours.txt`）⇒ 退出非 0、stderr 三行、
    目录不变；且因为 `pg-ops-shared` 先于四个 skill 安装，本宿主四个自属 skill 旧拷贝逐字节不变。
    """

    def test_foreign_pg_ops_shared_refused_and_skills_untouched(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        shared_dir = dest / "pg-ops-shared"
        shared_dir.mkdir()
        (shared_dir / "not-ours.txt").write_text("not managed by pg-ops\n")

        skill_snapshots = {}
        for skill in NEW_SKILLS:
            copy_dir = dest / skill
            copy_dir.mkdir()
            (copy_dir / MARKER).write_text("deadbeef\n")
            (copy_dir / "stale-file.txt").write_text("from the old copy\n")
            skill_snapshots[skill] = {
                MARKER: (copy_dir / MARKER).read_text(),
                "stale-file.txt": (copy_dir / "stale-file.txt").read_text(),
            }

        result = _run_setup(home, extra_path=extra_path, stdin_data="")

        assert result.returncode != 0
        fail_lines = [line for line in result.stderr.splitlines() if "[FAIL]" in line]
        assert len(fail_lines) == 3, f"expected exactly 3 [FAIL] lines, got: {fail_lines}"
        assert "problem:" in result.stderr
        assert "cause:" in result.stderr
        assert "fix:" in result.stderr

        assert (shared_dir / "not-ours.txt").read_text() == "not managed by pg-ops\n"
        assert not (shared_dir / MARKER).exists()

        for skill in NEW_SKILLS:
            copy_dir = dest / skill
            assert (copy_dir / MARKER).read_text() == skill_snapshots[skill][MARKER]
            assert (copy_dir / "stale-file.txt").read_text() == skill_snapshots[skill]["stale-file.txt"]


class TestLegacySharedResidualHint:
    """3.6 旧 `shared/` 残留提示：含本仓旧标记 `.pg-ops` ⇒ stdout 一行提示（含路径 / 「旧安装
    残留」/「确认其中无他仓仍在使用的文件后可手动删除」），文件不变；不含标记 ⇒ 不提示。
    """

    def test_hint_present_when_marked(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        shared_dir = dest / "shared"
        shared_dir.mkdir()
        (shared_dir / MARKER).write_text("oldsha\n")
        (shared_dir / "pgops-env.sh").write_text("# old copy\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr

        shared_path_str = str(shared_dir)
        assert shared_path_str in result.stdout
        assert "旧安装残留" in result.stdout
        assert "确认其中无他仓仍在使用的文件后可手动删除" in result.stdout
        assert (shared_dir / MARKER).read_text() == "oldsha\n"
        assert (shared_dir / "pgops-env.sh").read_text() == "# old copy\n"

    def test_hint_absent_when_unmarked(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)

        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        shared_dir = dest / "shared"
        shared_dir.mkdir()
        (shared_dir / "other-suite-script.sh").write_text("# another suite's script\n")

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        assert result.returncode == 0, result.stderr
        assert "旧安装残留" not in result.stdout


class TestUnixNoPgOpsShared:
    """3.7 Unix 全新安装后两宿主下均不出现 `pg-ops-shared` 与 `shared`。"""

    def test_unix_fresh_install_has_neither_dir(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()

        result = _run_setup(home)
        assert result.returncode == 0, result.stderr

        for host in HOSTS:
            dest = home / host
            assert not (dest / "pg-ops-shared").exists()
            assert not (dest / "shared").exists()


class TestWindowsSymlinkTargetRefused:
    """3.9 [spec-review-amendment] Windows 拷贝模式对任何软链目标一律拒装（不跟随判所有权）：
    `pg-ops-shared` 为「指向无标记目录的有效软链」「指向带标记目录的有效软链」「悬空软链」三种
    形态，以及一个 skill（`pg-dev-init`）为「指向带标记目录的软链」，均退出非 0、stderr 三行
    含「是软链」、`readlink` 与被指向目录内容不变。
    """

    def _assert_refused_and_untouched(self, result, link_path: Path, expected_target: str, target_dir: Path | None, expected_files: dict[str, str]):
        assert result.returncode != 0
        assert "是软链" in result.stderr
        fail_lines = [line for line in result.stderr.splitlines() if "[FAIL]" in line]
        assert len(fail_lines) == 3, f"expected exactly 3 [FAIL] lines, got: {fail_lines}"
        assert "problem:" in result.stderr
        assert "cause:" in result.stderr
        assert "fix:" in result.stderr
        assert link_path.is_symlink()
        assert os.readlink(link_path) == expected_target
        if target_dir is not None:
            for name, content in expected_files.items():
                assert (target_dir / name).read_text() == content

    def test_symlink_to_unmarked_dir(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)
        target_real = tmp_path / "unmarked-target"
        target_real.mkdir()
        (target_real / "foo.txt").write_text("bar\n")
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        (dest / "pg-ops-shared").symlink_to(target_real)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        self._assert_refused_and_untouched(
            result, dest / "pg-ops-shared", str(target_real), target_real, {"foo.txt": "bar\n"}
        )

    def test_symlink_to_marked_dir(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)
        target_real = tmp_path / "marked-target"
        target_real.mkdir()
        (target_real / MARKER).write_text("deadbeef\n")
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        (dest / "pg-ops-shared").symlink_to(target_real)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        self._assert_refused_and_untouched(
            result, dest / "pg-ops-shared", str(target_real), target_real, {MARKER: "deadbeef\n"}
        )

    def test_dangling_symlink(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)
        nonexistent = tmp_path / "does-not-exist"
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        (dest / "pg-ops-shared").symlink_to(nonexistent)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        self._assert_refused_and_untouched(
            result, dest / "pg-ops-shared", str(nonexistent), None, {}
        )

    def test_skill_target_symlink_to_marked_dir(self, tmp_path: Path):
        home = tmp_path / "home"
        home.mkdir()
        extra_path = _fake_windows_uname(tmp_path)
        target_real = tmp_path / "marked-skill-target"
        target_real.mkdir()
        (target_real / MARKER).write_text("deadbeef\n")
        dest = home / HOSTS[0]
        dest.mkdir(parents=True)
        (dest / "pg-dev-init").symlink_to(target_real)

        result = _run_setup(home, extra_path=extra_path, stdin_data="")
        self._assert_refused_and_untouched(
            result, dest / "pg-dev-init", str(target_real), target_real, {MARKER: "deadbeef\n"}
        )

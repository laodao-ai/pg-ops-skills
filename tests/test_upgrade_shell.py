"""Offline tests for pg-ops-upgrade/scripts/upgrade.sh entry guards."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
UPGRADE_SH = REPO_ROOT / "pg-ops-upgrade" / "scripts" / "upgrade.sh"


def _run_upgrade(cwd: Path, home: Path) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    return subprocess.run(
        ["bash", str(UPGRADE_SH)],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


class TestUpgradeCwdGuard:
    """工作目录在 skills 安装根下 ⇒ 在任何 git 操作前 fail-loud。"""

    def test_refuses_cwd_under_claude_skills(self, tmp_path: Path):
        home = tmp_path / "home"
        skill_dir = home / ".claude" / "skills" / "pg-ops-upgrade"
        skill_dir.mkdir(parents=True)

        result = _run_upgrade(cwd=skill_dir, home=home)

        assert result.returncode == 1
        assert "problem:" in result.stderr
        assert "skills 安装目录" in result.stderr
        assert "绝对路径" in result.stderr

    def test_refuses_cwd_under_agents_skills(self, tmp_path: Path):
        home = tmp_path / "home"
        skill_dir = home / ".agents" / "skills" / "pg-ops-upgrade"
        skill_dir.mkdir(parents=True)

        result = _run_upgrade(cwd=skill_dir, home=home)

        assert result.returncode == 1
        assert "skills 安装目录" in result.stderr

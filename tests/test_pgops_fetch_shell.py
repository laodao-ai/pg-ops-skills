"""Shell-layer tests for shared/pgops-fetch.sh's argument contract and local
landing-spot derivation (spec dev-side-secrets-boundary SEC-02, T73).

No server needed: a mock `ssh` binary is put first on PATH. It never connects
anywhere — it just echoes a marker naming the remote path it was asked to cat,
so a test can assert *which* remote file ended up in *which* local file. That
mapping is the whole point of T73: the local spot is derived from the remote
path (`/opt/pg-ops/<rel>` -> `.pg-ops/<rel>`) instead of being named by the
caller, so two remote documents can no longer land on one local name.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PGOPS_FETCH_SH = REPO_ROOT / "shared" / "pgops-fetch.sh"

MOCK_SSH = r"""#!/bin/bash
# Mock ssh for tests/test_pgops_fetch_shell.py — connects to nothing.
# pgops-fetch.sh invokes: ssh <opts...> -- <host> sudo cat -- <remote>
# Echo a marker naming the remote path so the caller can prove which remote
# file landed where. DBSKILLS_TEST_SSH_FAIL=1 simulates an unreachable server.
if [[ -n "${DBSKILLS_TEST_SSH_FAIL:-}" ]]; then
    echo "ssh: connect failed (mock)" >&2
    exit 255
fi
for a in "$@"; do last="$a"; done
printf 'CONTENT-OF:%s\n' "${last}"
"""


@pytest.fixture()
def project(tmp_path: Path):
    """A throwaway consuming-project cwd with a mock `ssh` first on PATH.
    Returns (root, env)."""
    root = tmp_path / "project"
    root.mkdir()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    mock_ssh = bin_dir / "ssh"
    mock_ssh.write_text(MOCK_SSH)
    mock_ssh.chmod(mock_ssh.stat().st_mode | stat.S_IEXEC)

    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    return root, env


def _run(root: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", str(PGOPS_FETCH_SH), *args],
        cwd=root, env=env, capture_output=True, text=True, timeout=30,
    )


# --- landing spot is derived, and mirrors the server layout ------------------


def test_landing_spot_derived_from_remote_path(project):
    root, env = project
    result = _run(root, env, "dev", "/opt/pg-ops/projects/myproj.md")

    assert result.returncode == 0, result.stderr
    landed = root / ".pg-ops" / "projects" / "myproj.md"
    assert landed.exists()
    assert "CONTENT-OF:/opt/pg-ops/projects/myproj.md" in landed.read_text()
    assert ".pg-ops/projects/myproj.md" in result.stdout


def test_two_remote_docs_never_collide_on_one_local_name(project):
    """The T73 defect itself: with a caller-chosen third argument both of these
    defaulted to .pg-ops/pg-dev-init.md, so the second silently overwrote the
    first and the reader could not tell which database the file described."""
    root, env = project
    assert _run(root, env, "dev", "/opt/pg-ops/projects/alpha.md").returncode == 0
    assert _run(root, env, "dev", "/opt/pg-ops/projects/beta.md").returncode == 0

    alpha = root / ".pg-ops" / "projects" / "alpha.md"
    beta = root / ".pg-ops" / "projects" / "beta.md"
    assert "CONTENT-OF:/opt/pg-ops/projects/alpha.md" in alpha.read_text()
    assert "CONTENT-OF:/opt/pg-ops/projects/beta.md" in beta.read_text()


def test_root_level_remote_file_lands_at_pg_ops_root(project):
    root, env = project
    assert _run(root, env, "dev", "/opt/pg-ops/handover.md").returncode == 0
    assert (root / ".pg-ops" / "handover.md").exists()


# --- the removed third argument fails loud ----------------------------------


def test_legacy_three_argument_call_fails_loud(project):
    """Silently ignoring it would move the file somewhere the caller did not
    ask for while reporting success — worse than refusing."""
    root, env = project
    result = _run(root, env, "dev", "/opt/pg-ops/handover.md", ".pg-ops/handover.md")

    assert result.returncode != 0
    assert "problem:" in result.stderr
    assert not (root / ".pg-ops" / "handover.md").exists()


# --- remote path validation --------------------------------------------------


@pytest.mark.parametrize(
    "remote",
    [
        "/etc/passwd",                      # outside /opt/pg-ops/
        "/opt/pg-ops/../../etc/passwd",     # traversal
        "/opt/pg-ops/",                     # the directory itself, not a file
    ],
)
def test_illegal_remote_path_rejected_with_no_local_file(project, remote):
    root, env = project
    result = _run(root, env, "dev", remote)

    assert result.returncode != 0, remote
    assert "problem:" in result.stderr, remote
    assert not (root / ".pg-ops").exists() or not any(
        (root / ".pg-ops").rglob("*.md")
    ), remote


@pytest.mark.parametrize("host", ["-oProxyCommand=x", "a b", "host;rm"])
def test_illegal_host_rejected(project, host):
    root, env = project
    result = _run(root, env, host, "/opt/pg-ops/handover.md")

    assert result.returncode != 0, host
    assert "problem:" in result.stderr, host


# --- failure leaves nothing behind -------------------------------------------


def test_ssh_failure_leaves_no_target_file(project):
    root, env = project
    env["DBSKILLS_TEST_SSH_FAIL"] = "1"

    result = _run(root, env, "dev", "/opt/pg-ops/projects/myproj.md")

    assert result.returncode != 0
    assert "problem:" in result.stderr
    assert not (root / ".pg-ops" / "projects" / "myproj.md").exists()
    leftovers = list((root / ".pg-ops" / "projects").glob(".pgops-fetch.*"))
    assert leftovers == [], f"temp file left behind: {leftovers}"

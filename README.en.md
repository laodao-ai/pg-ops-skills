# pg-ops

A standalone, globally-installed PostgreSQL **ops engine repo**: stand up and operate the
PostgreSQL service itself — provisioning, backup/restore, prod→dev sync, monitoring, roles.
Extracted from the production ops practice of a Go service (2026-09-04).

See `README.md` (Chinese, the primary/canonical doc) for the full skill table, directory layout,
and per-key configuration reference.

This repo is the **engine**: consuming projects wire it in through one seam at their own project
root — `.pg-ops/` (owner credentials, never touched by the model). It is also **its own consuming
project** (decided 2026-09-09, "testing is consumption"): it has its own dev/test database and its
own `.pg-ops/`, and it uses its own skills to develop and test itself. That does not weaken the
boundary rule above — the rule constrains **what goes into a skill** (the engine must never name a
specific consuming project's binaries, schemas, or layout), not whether this repo happens to have a
database of its own.

## Security model

The `.pg-ops/` seam (owner-level credentials). The model never reads this directory directly;
server-rendered scripts write handover docs there, and a human retrieves file contents via
`shared/pgops-fetch.sh` rather than having them printed to model stdout (see ADR-0002).
Production-side scripts are dump/read-only only — never a write path into production — and are
copied to the production host as a self-contained bundle (script + a separate env template the
human fills in on the production host itself); the model never reads a production env file
(see ADR-0001).

Install/provisioning scripts never touch data they don't own, and re-running is always a safe
no-op.

## Install

```bash
git clone https://github.com/laodao-ai/pg-ops.git ~/.skills/pg-ops   # a real clone, not a symlink into a dev checkout
bash ~/.skills/pg-ops/setup.sh                                       # idempotent; symlinks on Unix, copies on Windows
```

This installs the 3 skills plus the `pg-ops-upgrade` upgrade skill into both `~/.claude/skills/`
and `~/.codex/skills/`. Afterwards,
upgrade with `/pg-ops-upgrade` (pull → setup → show version). Development happens in a separate dev
checkout; the run checkout is pull-only, never edited in place.

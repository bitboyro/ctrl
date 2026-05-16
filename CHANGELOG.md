# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- GitHub Actions test suite (`.github/workflows/test.yml`) with five jobs: ShellCheck lint, unit tests (Ubuntu + macOS matrix), randomized property tests, `dist/ctrl` smoke tests, and SSH integration tests against a `linuxserver/openssh-server` service container. 59 bats-core tests under `tests/` cover Properties 1, 2, 3, 4, 5, 7, 8, and 14 from the design doc, plus MCP JSON-RPC and journal round-trips. Release workflow now requires the test workflow to pass before tagging.

## [0.1.0] - 2026-05-16

### Added
- Structured script template — `ctrl script init <name>` now generates scripts with path detection (`SCRIPT_DIR`, `CTRL_ROOT`), deployment context detection (`DEPLOYMENT_DIR`, `DEPLOYMENT_NAME`), core library loading with inline fallback stubs, `_check_deps` / `_usage` functions, `--help` / `--dry-run` / `--output` flag parsing, entry-point guard (sourceable or executable), and a cleanup trap.
- Template override — if `scripts/templates/ctrl-script.sh` exists in the project, it is used instead of the built-in template; falls back to built-in with a warning if missing/unreadable.
- `.local/` convention — `ctrl init` creates a gitignored `.local/` directory with `.gitignore` (`*`) and `secrets.env.example`. `load_config()` auto-sources `.local/secrets.env` even when not listed in `meta.env_files`. Journal is written to `<project>/.local/journal/journal.jsonl` when `.local/` exists, falling back to `~/.local/share/ctrl/journal.jsonl`.
- Version mismatch detection — `ctrl check` warns when the running ctrl version differs from `ctrl.version` declared in `ctrl.yaml`.
- `install.sh` accepts an explicit version argument (`./install.sh v0.1.0`); without an argument it installs from `main`.
- Vendored ctrl probe — `ctrl_find_vendored()` helper exposed for downstream wrappers to locate `vendor/ctrl/ctrl.sh` or `.ctrl/ctrl.sh` relative to a project's `ctrl.yaml`.
- Script tag filtering — `ctrl scripts --tag <tag>` filters the script list by the `tags:` field declared on each script.
- Machine password support — `machines.hosts[].password` resolves through `_resolve_env_refs` and is exported as `CTRL_META_SSH_PASSWORD`. `ctrl_ssh_run`, `ctrl_scp_send`, and `open_ssh` use it via `sshpass`; missing `sshpass` produces a clear install hint. Password values are redacted from dry-run output.
- Script execution context — `run_script()` now also exports `CTRL_MACHINE_NAME` and `CTRL_DEPLOY_NAME` alongside existing variables.

### Changed
- SSH helpers no longer read the loose `SSH_PASSWORD` environment variable. Password auth is now driven exclusively by `machines.hosts[].password` (which itself can reference `${SSH_PASSWORD}` from `.local/secrets.env`). Workspaces that relied on the bare env var must add `password:` to their machine definition.

### Fixed
- `ctrl scripts`, `ctrl sc`, and `ctrl script list` no longer fail on newer `yq` releases; script listing now uses a compatible expression format.
- `ctrl hc` now skips `kind: library` entries and only expands `all` to services that actually have a configured health target, so SDK modules no longer appear as noisy pseudo-services in health runs.
- MCP server (`ctrl mcp`) was emitting pretty-printed multi-line JSON; responses are now compact single-line JSON-RPC as required by the MCP stdio transport.

## [0.0.1] - 2026-05-04

### Added
- `machines:` block — SSH hosts as a first-class concept; `deployments:` reference machines by name
- Two independent defaults: `machines.default` and `deployments.default`
- `kind: external` — third-party images; build/push blocked with a clear error
- New commands: `diff`, `machines` / `m`, `info`, `check` / `c`, `tag` / `t`, `default`, `script init`, `init`, `mcp`
- `--json` flag for `list`, `hc`, `info`, `diff`, `check`, `sc`, `machines`
- `--dry-run` shorthand `-n`
- MCP server (`ctrl mcp`) — JSON-RPC 2.0 over stdio, exposes ctrl as tools for Claude/agents
- Agent definitions: `milli.agent.md`, `seb.agent.md`, `asam.agent.md`
- `build.sh` — single-file `dist/ctrl` for distribution; GitHub Actions release on `v*` tag

### Changed
- `meta.ssh_host/user/port/key/compose_path` moved to `machines:` + `deployments:` model
- Shorthands unified to first-letter scheme: `p` (push), `r` (release), `s` (sync), `d` (deploy)
- `inspect` / `insp` renamed to `env` / `e`
- `ctrl list` — added KIND and BUILD columns
- Persona rename: Masamune → Asam
- Bug fixes: docker login credentials (B1), `ctrl wr` dry-run (B2), `ctrl st` env block (B3)

### Removed
- `ctrl plan` — use `--dry-run` instead

## [0.0.0] - 2026-04-18

Initial release — versioned, YAML-driven platform CLI with build, push, deploy, SSH, health-check,
smoke-test, audit journal, script extensions, and Claude skill.

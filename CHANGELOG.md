# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- `ctrl deploy`, `ctrl redeploy`, and `ctrl sync-deploy` no longer crash with `local: can only be used in a function` when run from the packaged CLI. The dispatcher no longer declares `local` variables at top level, and smoke coverage now exercises bundled `redeploy` in dry-run mode.

## [0.2.4] - 2026-05-27

### Changed
- Bump version to 0.2.4 for release.

## [0.2.3] - 2026-05-25

### Changed
- `README.md` now clarifies that packet capture is exposed as `ctrl probe sniff`, not as standalone `ctrl sniff` / `ctrl capture`, and removes wording that implied remote captures are pulled back automatically.

### Fixed
- `dist/ctrl` now bundles `lib/cp.sh`, so packaged installs correctly provide the `ctrl cp` command instead of failing with `ctrl_cp: command not found`.

### Added
- Smoke coverage for the packaged `ctrl cp` command to prevent bundling regressions in `dist/ctrl`.

## [0.2.1] - 2026-05-25

### Changed
- `README.md` now documents `ctrl help <command>` and adds a dedicated `ctrl cp` usage section with local/remote copy examples.
- README version examples now reference the current 0.2.x series instead of older 0.1.x snippets.

### Fixed
- `ctrl help` no longer prints the stray `CTRL_HELP_MARKER` line in top-level help output.
- `ctrl help cp` is now supported, and `ctrl cp` is listed in the top-level help output and zsh help completion suggestions.

## [0.2.0] - 2026-05-25

### Added
- `ctrl ping <svc|machine>` — HTTP ping a service's health URL or TCP ping a machine, with per-request latency and min/avg/max/loss summary. Only accepts names registered in `ctrl.yaml`.
- `ctrl call <svc> <path>` — authenticated REST call against a named service. Base URL resolved from `health.port` or `api.base_url`. Injects `Authorization: Bearer $JWT_TOKEN` if set. Flags: `--method`, `--body`, `--header`.
- `ctrl probe` — unified diagnostics command with three modes:
  - `ctrl probe <svc|machine>` — HTTP or TCP connectivity check.
  - `ctrl probe sniff <svc>` — live tcpdump via the `ghcr.io/bitboyro/ctrl-tools` container on the service's Docker network; `--host` for host-level tcpdump; `--save` writes to `.local/captures/`; deployment target runs the capture remotely.
  - `ctrl probe shell` — interactive shell inside ctrl-tools container; `--network`, `--mount`, `--no-network` flags.
- `ctrl doctor [--install]` — pre-flight dependency check. Reports required and optional tools, checks all `${VAR}` references in `ctrl.yaml` against current env, validates the config. `--install` auto-installs missing tools using the best available method (pip → brew → apt-get → curl). Reads `meta.tools[]` from `ctrl.yaml` for project-specific tool hints.
- `ctrl completion <bash|zsh>` — print shell completion script. Dynamically completes service names, machine names, and script names from ctrl.yaml. Install with `eval "$(ctrl completion bash)"`.
- `meta.tools[]` block in `ctrl.yaml` — declare project-specific tool dependencies with install hints for pip, brew, and curl. Used by `ctrl doctor`.
- Per-command help: `ctrl help <command>` prints a focused page with description, ctrl.yaml fields read, flags, and examples. Supported for: `build`, `image`, `push`, `release`, `deploy`, `ssh`, `remote-logs`, `health-check`, `ping`, `call`, `probe`, `doctor`, `diff`, `run`.
- `lib/probe.sh` — implementation for `ctrl ping`, `ctrl call`, `ctrl probe`.
- `lib/doctor.sh` — implementation for `ctrl doctor`.
- `completions/ctrl.bash` and `completions/ctrl.zsh` — shell completion scripts.
- `ctrl cp` — copy files and directories between local paths and named machines from `ctrl.yaml` using `rsync`. Supports local-to-local, local-to-remote, remote-to-local, and remote-to-remote transfers, plus `--exclude`, `--delete`, and `--progress` flags. Remote transfers reuse the configured SSH machine settings, and remote-to-remote copies are performed via a temporary local bounce.

### Changed
- `ctrl help` rewritten: quick-start block at top, per-group examples inline, consistent column alignment, deps line at the bottom (`ctrl doctor` hint).
- All commands now journaled. Previously only build/deploy pipeline commands were written to the audit journal. Added `with_journal` wrapping for: `ssh`, `remote-status`, `remote-logs`, `env`, `health-check`, `wait-ready`, `smoke-test`, `run`, `diff`, `check`, `tag`, `default`.
- Agent definitions updated — all three personas (`milli`, `seb`, `asam`) now document their preference for ctrl commands over raw shell, with explicit fallback policy.
- `SKILL.md` — added Constraints section documenting the ctrl-first rule for all three personas.
- `README.md` — added Shell completion, Diagnostics, Workflows, and Troubleshooting sections; updated deps table with new entries.

### Fixed
- ShellCheck cleanup for release packaging and CI: `lib/cp.sh` now declares Bash explicitly, and `lib/doctor.sh` no longer keeps an unused `ctrl_check` capture.

## [0.1.2] - 2026-05-20

### Fixed
- `deploy`, `redeploy`, and `sync-deploy` commands no longer crash with `unbound variable` when an unknown service name is given. The subshell exit code from `ctrl_resolve_services` was previously swallowed by `read`; now captured into a variable first so `|| exit 1` correctly propagates the failure.
- `ctrl help` now lists the existing `list` / `ls`, `check` / `c`, and `tag` / `t` commands correctly, and documents script listing via `ctrl script` / `ctrl script list`.
- `ctrl ssh` no longer hardcodes the interactive start directory to the deployment compose directory. `machines.hosts[].cwd` now sets a per-machine default, and `deployments.targets[].cwd` can override it per deployment while compose-driven commands keep using `compose_path`.
- `ctrl` no longer carries `scaffold`-specific defaults or examples; bundled defaults, docs, and templates now use generic paths and wording.

### Added
- `deployments.targets[].sync.base` — optional local subdir prepended to each `sync.paths` entry, letting projects keep source files under a subdirectory (e.g. `dist/`) while the remote layout stays relative to the target's `compose_path` dir.

## [0.1.1] - 2026-05-16

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
- `ctrl sync` now preserves each configured relative `sync.paths` entry on the remote host instead of flattening files into the deployment root; password-auth SSH integration tests are now robust regardless of where `sshpass` is installed.
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

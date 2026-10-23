# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

## [0.4.1] - 2026-10-23

### Fixed
- Return a non-zero exit status when service or `ctrl run --on` target resolution fails under Bash 5, including MCP service tools.
- Isolate the sniff duration test from the local Docker installation by using a fake Docker command.

## [0.4.0] - 2026-10-11

One command for every script. `ctrl run` now runs project scripts and a bundled
library on this machine or on any set of hosts, with one fixed set of
modifiers. Overlapping commands are merged, rarely used ones became bundled
scripts, and ctrl knows which OS, architecture and package manager it is on.
See README → "Migrating from 0.3".

### Added
- **`ctrl run` engine** (`lib/scripts.sh`):
  - **Resolution:** a `ctrl.yaml` entry with a path first, then `scripts/<name>.sh` (auto-discovered, no entry needed), then a bundled script.
  - **Modifiers, the same for every script:**
    - `--on local|<target>|a,b|@tag|all` — several targets run in parallel, with host-prefixed output, a per-host summary and a combined exit code.
    - `--check` — pre-flight only, on every host.
    - `--show` — header and source; for a project copy, the diff against the bundled version.
    - `--own` — copy a bundled script into `scripts/` with its helpers inlined, so it runs standalone.
    - `-n` — for `@dry-run` scripts, prints their exact commands.
    - `--yes` — confirms `@sudo` scripts.
  - **Listing:** `ctrl run` with no name lists every script, grouped (`--tag`, `--json`).
- **Script headers** (`# @description`, `@group`, `@tags`, `@requires`, `@env`, `@env-optional`, `@os`, `@remote`, `@sudo`, `@dry-run`, `@flags`, read from the first 60 lines):
  - A `ctrl.yaml` entry overrides any of them; `scripts[].path` is now optional.
  - One pre-flight covers OS, tools (with the install command for that host's package manager), env vars and sudo, locally and inside the remote preamble.
  - `@env` / `@env-optional` values are forwarded to `--on` hosts over stdin, never in argv.
- **Bundled library (30 scripts)**, embedded in `dist/ctrl`:
  - **dev:**
    - `lint` — detects file types and runs the right linter for each (shellcheck, hadolint, yamllint or a yq parse, actionlint, jq, ruff, eslint, gofmt/go vet, `ctrl check`); supports `--changed`, `--fix`, `--only` and `--list`.
    - `loc` — code, comment and blank lines by language, folder or file, with `--json`.
    - `churn` — git activity by author or file, and hotspot files (changes × size).
  - **media:** `rec`, `gif`, `shrink`, `snap`
  - **share:** `share`, `qr`
  - **setup:** `install-docker` (repo key fingerprint verified), `add-swap`, `harden-ssh` (lock-out guards, `sshd -t`), `ufw-basics`, `install-tailscale`, `timezone`
  - **docker:** `dsh`, `dtop`, `dclean`
  - **network:** `ports`, `myip`, `certs`, `sniff`, `toolbox`, `api-call`
  - **system:** `sysinfo`, `hogs`
  - **ci:** `gitlab-info`, `gitlab-runner` (SHA256-verified binary)
  - **project / meta:** `smoke`, `new-script`
  - Every script works with no arguments, prints its commands under `-n`, and asks before changing the system.
- **Platform awareness** (`lib/platform.sh`):
  - Detects `CTRL_OS`, `CTRL_ARCH` and `CTRL_PKG` (brew/apt/dnf/apk); each can be overridden.
  - Portable `ctrl_now_ms` and `ctrl_realpath` helpers.
  - Stock macOS Bash 3.2 is supported.
- **Tool registry** (`lib/tools.yaml`): package names per manager, single-binary URLs with `{os}`/`{arch}`, and `check`/`min` version rules. `ctrl.yaml` `meta.tools[]` uses the same shape and is merged on top.
- **`ctrl doctor`:**
  - Driven by the registry: shows the platform, detects versions that are too old, and prints the exact install command.
  - Works without a `ctrl.yaml`.
  - `ctrl doctor <machine>` checks a host: OS, docker, compose v2, rsync, curl, sudo.
- **`ctrl hc`:** `--wait N`, `--count N [--interval S]`, `--tcp`, `--port N`; accepts machines as well as services.
- **`ctrl deploy`:** `--release` and `--sync` flags.
- **`ctrl list`:** `ctrl list machines`.
- **`ctrl set`:** `ctrl set tag` and `ctrl set default`.
- **`machines.hosts[].tags`**, used by `--on @tag`.
- **MCP tools:**
  - New: `run_list`, and `run {name, args, on, check, dry_run, yes}`.
  - Every tool declares whether its output is JSON or text.
  - The server works outside a project.
- **Help for removed commands:** each removed command prints its replacement, both when run and in `ctrl help <cmd>`.
- **`ctrl upgrade`:** it was documented but never implemented. It reads the latest release, prints the CHANGELOG sections since your version, then SHA256-verifies, sanity-checks and atomically replaces a single-file install.
- **Release checksum:** the release workflow publishes `ctrl.sha256` alongside `dist/ctrl`.
- **Tests:** 305 tests, up from 151. New suites:
  - `test_run_engine`, `test_run_on` (fan-out through a fake ssh), `test_bundled` (the library contract plus a dry-run for each script), `test_dev_scripts` (lint with fake linters, exact loc counts, churn on a throwaway repo), `test_hostile_input`, `test_upgrade_install`.
  - Real-SSH `run --on` tests against the CI sshd.
  - CI lints `bundled/`, the completions and `tests/` with ShellCheck. The known false positives are recorded in `bundled/.shellcheckrc` and `tests/.shellcheckrc`, so CI, editors and `ctrl run lint` agree; the repo passes `ctrl run lint`.

### Changed
- `ctrl.yaml` is optional for `run`, `doctor` and `mcp`.
- `ctrl check` now also:
  - rejects names that aren't plain tokens (services, compose services, `depends_on`, machines, tags, deployments, scripts);
  - lints the headers in `scripts/*.sh`;
  - accepts `smoke_tests` that name discovered or bundled scripts.
- Journal entries are built with `jq`. `run --on` writes one entry per host.
- `${VAR}` / `$VAR` expansion in `ctrl.yaml` is pure Bash. It replaces `envsubst`, which stock macOS doesn't ship, and expands the same two forms.
- Extensions define `ctrl_ext_cmd_<name>`; `ctrl_cmd_<name>` still works.
- Shell completions have been rewritten for the new command set.
- `install.sh`:
  - installs the SHA256-verified release binary (latest, or a given `vX.Y.Z`);
  - `--main` installs the source tree from the repository archive, with no file list to go stale;
  - it previously failed, because it tried to download the `agents/` files that 0.3.0 removed.

### Removed
- **Commands folded into others:**
  - `cpr`/`copy-run` → `run --on`
  - `scripts`/`sc` → `run`
  - `script init` → `run new-script`
  - `redeploy` → `deploy --release`; `sync-deploy` → `deploy --sync`
  - `wait-ready` / `ping` / `probe <x>` → `hc`
  - `machines` → `list machines`
  - `tag` / `default` → `set`
- **Commands that became bundled scripts:**
  - `probe sniff` → `run sniff`; `probe shell` → `run toolbox`
  - `call` → `run api-call`; `smoke-test` → `run smoke`
  - `gitlab-project-info` → `run gitlab-info`; `gitlab-runner-deploy` → `run gitlab-runner`
- `lib/probe.sh`, `lib/gitlab.sh`, `lib/templates.sh`.

### Security
- Values from the CLI, `ctrl.yaml` and MCP parameters reach yq only through `strenv()`. They are never spliced into expressions, including the `.local/ctrl.local.yaml` merge path.
- Names must be plain tokens (`[A-Za-z0-9][A-Za-z0-9_.-]*`). They are validated before they reach yq, remote shells or `ctrl.yaml` writes.
- **MCP:**
  - Parameters are validated up front.
  - Tool work runs in subshells, and malformed output turns into an error, so a failing tool no longer kills the server.
- Remote arguments, `@env` values, health URLs and SSH key paths are quoted (`printf %q`); script args and env travel on stdin.
- **Secrets are kept out of process listings (`ps`):**
  - the GitLab token and `JWT_TOKEN` go to curl through stdin;
  - the runner token goes through the environment;
  - the Tailscale key goes through a 0600 file;
  - `DOCKERHUB_PASSWORD` is unset after login.
- No `eval` anywhere. `doctor --install` runs argv arrays built from package names, and downloads must be `https`. The old `curl | sudo bash` runner install is gone.
- Extensions load only if they are `.sh` files inside the project tree.
- `sniff --duration` must be an integer, and filters are passed as a single quoted tcpdump expression.
- Build directories and `build.script` are passed to `bash -c` as positional parameters.
- `ctrl init` validates everything it writes into YAML.

### Fixed
- `ctrl doctor --install` no longer installs the pip `yq` (a different tool that broke ctrl) or builds `pip install pip install …`.
- **macOS:**
  - latency timing no longer uses GNU `date +%s%3N`;
  - no `readlink -f` at startup;
  - no dependency on `envsubst`.
- `hc` no longer exits silently when there is no default deployment, and latency summaries are no longer computed with `bc`.
- MCP `build_service`/`release_service` report failures; `diff` uses `jq --arg`.
- The `run` listing keeps descriptions and empty columns intact.
- Five tests in the suite asserted nothing under Bash 3.2 (a failing `[[ ]]` in the middle of a test is ignored). Their assertions are now explicit.

## [0.3.0] - 2026-06-20

### Added
- `ctrl copy-run <name> [target]` (alias: `ctrl cpr`) — pipe a named script to the remote host via SSH and run it there. Injects the same `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY`, `CTRL_REMOTE_DIR` env vars as `ctrl run`. Nothing is left on the remote — the script is streamed via `bash -s`. Supports dry-run, password auth, and optional deployment target as second arg.
- `requires` block on `scripts[]` entries in `ctrl.yaml` — declare `tools` and `env` that must be present before a script executes. `ctrl run` checks them on the local host; `ctrl cpr` injects a self-contained preamble that checks them on the remote host before the script body runs. Scripts without a `requires` block are unaffected.
- 61 new bats tests across six new unit test files: `test_resolve_services`, `test_service_accessors`, `test_check_invalid`, `test_tag_and_default`, `test_health_check` (curl mocked via PATH injection), and `test_requires`. Total test count: 151.

### Removed
- Autonomous agent harness subsystem — `lib/harness.sh`, `lib/heartbeat.sh`, `lib/observer.sh`, `lib/loop.sh` (1711 lines), all agent persona definitions (`agents/`), and all harness/heartbeat MCP tool entries. ctrl is a pure utility tool for humans and agents; it no longer controls agents, spawns skills, or runs background loops.

### Changed
- `SKILL.md` rewritten as a grouped, usage-oriented reference covering every ctrl command with bash examples — previously only listed a subset of commands.
- `backlog.md` added at project root — 37 security and correctness findings catalogued by severity (CRITICAL → LOW).

## [0.2.5] - 2026-05-27

### Added
- `machines.hosts[].remote_dir` — sets the working directory used by `ctrl rs`, `ctrl rl`, and `ctrl env` when a machine is resolved directly (without a deployment context).
- `deployments.targets[].remote_dir` — explicit working directory override for a deployment target, taking priority over the directory derived from `compose_path`.
- `CTRL_META_REMOTE_DIR` env var is now respected as a fallback default; previously it was always overwritten by the hardcoded `/opt/app`.

### Changed
- Remote working directory resolution now follows a strict priority order: `deployment.remote_dir` → `dirname(compose_path)` → `machine.remote_dir` → `$CTRL_META_REMOTE_DIR` env var → `/opt/app` default.

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

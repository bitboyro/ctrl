# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.0.1] - 2026-05-04

### Added
- `machines:` section — SSH hosts as a first-class concept, separate from deployments
- `deployments.targets[].machine` — deployments reference a named machine
- Two independent defaults: `machines.default` (ssh/rs/rl/env) and `deployments.default` (dep/diff/sync/hc)
- `kind: external` — third-party images; build/push/release are blocked with a clear error
- `ctrl diff [target]` — declares vs running image:tag drift detection via `docker compose images`
- `ctrl machines` / `m` — list all machines with host and deployment count
- `ctrl info [machine|svc]` — project info, machine detail, or service detail; supports `--json`
- `ctrl check` / `c` — validates ctrl.yaml structure and file references; supports `--json`
- `ctrl tag` / `t` — updates service tag in ctrl.yaml in-place via `yq -i`
- `ctrl default` — sets `machines.default` or `deployments.default` in-place
- `ctrl script init <name>` — scaffolds a script from embedded template and registers in ctrl.yaml
- `ctrl init` — interactive wizard to generate ctrl.yaml; offers PATH setup for `~/.local/bin`
- `ctrl mcp` — stdio MCP server (JSON-RPC 2.0) exposing ctrl as tools for Claude/agents
- `--json` global flag — JSON output for list, hc, info, diff, check, sc, machines
- `--dry-run` shorthand `-n`
- `ctrl env` / `e` — show env of running container (renamed from `inspect`)
- Agent definitions: `agents/milli.agent.md`, `agents/seb.agent.md`, `agents/asam.agent.md`
- GitHub Actions release workflow: builds `dist/ctrl` on `v*` tag push
- `build.sh` — produces single-file `dist/ctrl` for distribution
- `.gitignore` — excludes `dist/`, `.local/`

### Changed
- `inspect` / `insp` renamed to `env` / `e`
- `push` shorthand changed from `pu` to `p` (consistent first-letter scheme)
- `sync` shorthand changed from `sync` to `s`
- `deploy` shorthand changed from `dep` to `d`
- `release` shorthand changed from `rel` to `r`
- Improved `ctrl list` — shows SERVICE, KIND, BUILD, IMAGE:TAG columns
- Persona rename: Masamune → Asam
- `meta.ssh_host/user/port/key/compose_path` moved to `machines:` + `deployments:` model
- Docker login fix (B1): credentials no longer interpolated into bash -c strings
- `ctrl wr` dry-run fix (B2): curl call now wrapped with `run_op`
- `ctrl st` env fix (B3): smoke tests now receive full CTRL_PROJECT/SSH_HOST/etc. env block
- `build.sh` replaces `bundle.sh`; outputs to `dist/ctrl`, embeds VERSION at build time

### Removed
- `ctrl plan` command — use `--dry-run` flag instead

## [0.1] - 2026-04-18

### Added
- Initial release of `ctrl` — versioned, YAML-driven platform CLI
- `ctrl.yaml` config schema with services, scripts, and extensions
- `install.sh` one-liner installer with skill and example config generation
- Commands: list, build, image, push, release, deploy, redeploy, sync-scaffold, ssh, remote-status, remote-logs, health-check, wait-ready, smoke-test, run, plan, history, version
- Structured JSON audit journal at `~/.local/share/ctrl/journal.jsonl`
- `--dry-run` and `--verbose` global flags
- Script extension system via `ctrl run <name>`
- Plugin extension system via sourced `extensions:` entries
- Claude skill (`SKILL.md`) for creating and maintaining `ctrl.yaml`

# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- `ctrl scripts`, `ctrl sc`, and `ctrl script list` no longer fail on newer `yq` releases; script listing now uses a compatible expression format.

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

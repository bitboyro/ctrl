# Changelog

All notable changes to ctrl will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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

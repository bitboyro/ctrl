# Plan: ctrl — Generic Platform CLI Tool

## Context

`platformctl.sh` in `scaffold/scripts/` works but is monolithic, hardcoded, not installable, and not extensible. The goal is to replace it with `ctrl` — a versioned, YAML-driven, installable Bash CLI that lives in its own repo (`ctrl/`), can be downloaded from GitHub/GitLab with a single `curl`, and ships as a first-class Claude skill so agents can create and maintain the project's `ctrl.yaml`.

Ideas are drawn from the devkit design in `reverseprompt.txt`: modular lib structure, 3-layer config, structured logging, journal/audit, dry-run, and a clear extension contract for scripts and plugins.

---

## Repository: `ctrl/` (standalone public repo)

### Directory layout

```
ctrl/
├── ctrl.sh                  ← single entry-point (chmod +x)
├── lib/
│   ├── core.sh              ← logging, config loader, env merge, OS detect
│   ├── services.sh          ← build, image, push, release commands
│   ├── deploy.sh            ← deploy-vm, redeploy, sync-scaffold
│   ├── remote.sh            ← ssh, remote-status, remote-logs, inspect
│   ├── health.sh            ← health-check, wait-ready, smoke-test
│   ├── audit.sh             ← journal writes, history, rollback metadata
│   └── ext.sh               ← script runner / plugin loader
├── schema/
│   └── ctrl.schema.yaml     ← JSON-schema-style spec for ctrl.yaml
├── docs/
│   └── ctrl.md              ← usage reference
├── install.sh               ← one-liner installer (curl | bash)
├── SKILL.md                 ← Claude skill definition
├── VERSION                  ← semver string, e.g. 0.1
└── CHANGELOG.md
```

---

## ctrl.yaml — config schema (project-side, not in ctrl repo)

Each project that uses `ctrl` maintains a `ctrl.yaml` in its root (gittracked, no secrets).

```yaml
ctrl:
  version: "0.1"           # minimum ctrl version required

meta:
  project: bitboy-platform
  registry: dockerhub.io/bitboyro
  ssh_host: "${VM_HOST}"     # env var reference — resolved at runtime
  ssh_user: root
  compose_path: /opt/scaffold/docker-compose.yml

services:
  - name: ork
    image: bitboyro/ork
    build:
      tool: maven
      dir: ../ork
    deploy:
      compose_service: ork
  - name: search
    image: bitboyro/search
    build:
      tool: maven
      dir: ../search
    deploy:
      compose_service: search
  # ... one entry per service

scripts:
  - name: seed-db
    path: scripts/seed-db.sh
    description: "Seed local postgres with fixture data"
  - name: rotate-keys
    path: scripts/rotate-keys.sh
    description: "Rotate Keycloak signing keys"

extensions:
  - path: ext/custom-checks.sh   # optional local extensions
```

Secrets never go in `ctrl.yaml`. They live in `.local/ctrl.local.yaml` (gitignored) or plain env vars. `core.sh` merges all three layers at startup.

---

## Install flow (versioned, public repo)

```bash
# Install specific version
curl -fsSL https://raw.githubusercontent.com/bitboyro/ctrl/v0.1/install.sh | bash

# install.sh does:
#   1. Detect OS / shell
#   2. Download ctrl.sh + lib/ to ~/.local/share/ctrl/<version>/
#   3. Symlink ~/.local/bin/ctrl → ctrl.sh
#   4. Detect if .claude/skills/ exists in CWD or home
#   5. Copy SKILL.md → .claude/skills/ctrl/SKILL.md (project) or
#      ~/.claude/skills/ctrl/SKILL.md (global fallback)
#   6. Print: ctrl v0.1 installed — skill registered at .claude/skills/ctrl/
```

If no `ctrl.yaml` exists in the current directory, `install.sh` also generates a commented `ctrl.yaml.example` (or `ctrl.yaml` if `--init` flag is passed) populated with annotated placeholders explaining every field — so the operator can fill in values or let the `ctrl` Claude skill scaffold it properly.

Alternatively, projects can vendor ctrl as a git submodule at `ctrl/`:
```bash
git submodule add https://github.com/bitboyro/ctrl ctrl-tool
```

---

## Command surface (replaces platformctl.sh)

```
ctrl list                          # list services from ctrl.yaml
ctrl build <svc|all>               # mvn/npm build locally
ctrl image <svc|all>               # docker build
ctrl push  <svc|all>               # docker push to registry
ctrl release <svc> <tag>           # build + tag + push
ctrl deploy <svc|all>              # deploy on remote VM via ssh
ctrl redeploy <svc|all>            # pull + restart on VM
ctrl sync-scaffold                 # rsync scaffold files to VM
ctrl ssh [cmd]                     # open ssh / run remote cmd
ctrl remote-status [svc]           # docker ps / compose ps on VM
ctrl remote-logs <svc> [--follow]  # docker logs on VM
ctrl health-check [svc]            # hit /actuator/health or /health
ctrl wait-ready <svc> [--timeout]  # poll until healthy
ctrl smoke-test [svc]              # run scripts tagged as smoke tests
ctrl run <script-name> [args]      # run a named script from ctrl.yaml
ctrl plan                          # dry-run: show what would happen
ctrl history                       # show audit journal
ctrl version                       # print ctrl version
```

Global flags: `--dry-run`, `--verbose`, `--config <path>` (override ctrl.yaml location).

---

## Core internals (lib/core.sh)

- `set -euo pipefail` throughout
- Config load order: `ctrl.yaml` → `.local/ctrl.local.yaml` → env vars (highest)
- Env var references in yaml (`"${VAR}"`) resolved via envsubst at parse time
- Logging: `msg`, `msg_ok`, `msg_warn`, `msg_error` → stderr; structured JSON journal to `~/.local/share/ctrl/journal.jsonl`
- Each operation appends a journal entry: `{ ts, version, project, command, services, host, operator, duration_s, exit_code }`
- `--dry-run` skips all mutating shell calls and prints `[DRY-RUN]` prefix

---

## Script extension system (lib/ext.sh)

Scripts listed under `scripts:` in `ctrl.yaml` are invoked via `ctrl run <name>`. They receive:
- `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY` as env vars
- No positional args from ctrl itself (pass via `[args]`)

Extensions under `extensions:` are sourced at startup and can define new subcommands by exporting a function named `ctrl_cmd_<name>`.

---

## Claude skill: `ctrl` (SKILL.md)

The skill file at `ctrl/SKILL.md` teaches Claude how to:
1. Create a `ctrl.yaml` for a new project (scaffold from schema)
2. Add/remove/rename a service entry
3. Add a named script
4. Upgrade the `ctrl.version` field when the tool is updated
5. Validate the yaml against `schema/ctrl.schema.yaml`

The skill is registered by copying (or symlinking) `ctrl/SKILL.md` into `.claude/skills/ctrl/SKILL.md` in the project repo — same pattern as the existing `front4j` skill.

---

## Migration from platformctl.sh

`platformctl.sh` stays in `scaffold/scripts/` during transition. After `ctrl` is bootstrapped and `ctrl.yaml` is verified, a single commit removes `platformctl.sh` and updates `CLAUDE.md` to reference `ctrl` as the default ops interface.

---

## Critical files to create/modify

| File | Action |
|---|---|
| `ctrl/ctrl.sh` | Create — entry point |
| `ctrl/lib/core.sh` | Create |
| `ctrl/lib/services.sh` | Create |
| `ctrl/lib/deploy.sh` | Create |
| `ctrl/lib/remote.sh` | Create |
| `ctrl/lib/health.sh` | Create |
| `ctrl/lib/audit.sh` | Create |
| `ctrl/lib/ext.sh` | Create |
| `ctrl/install.sh` | Create |
| `ctrl/SKILL.md` | Create |
| `ctrl/schema/ctrl.schema.yaml` | Create |
| `ctrl/VERSION` | Create (`0.1`) |
| `ctrl/CHANGELOG.md` | Create |
| `ctrl.yaml` (bitboy.ro root) | Create — project config |
| `.claude/skills/ctrl/SKILL.md` | Symlink or copy from ctrl/ |
| `.claude/CLAUDE.md` | Update — reference ctrl as default ops tool |
| `scaffold/scripts/platformctl.sh` | Remove after migration verified |

---

## Verification

1. `ctrl version` → prints `ctrl v0.1`
2. `ctrl list` → reads `ctrl.yaml`, prints all configured services
3. `ctrl build ork --dry-run` → prints `[DRY-RUN] mvn clean package -DskipTests` without executing
4. `ctrl run seed-db` → invokes `scripts/seed-db.sh` with env vars set
5. `ctrl history` → shows journal entries from `~/.local/share/ctrl/journal.jsonl`
6. Fresh install: `curl -fsSL .../install.sh | bash && ctrl version` works on a clean machine

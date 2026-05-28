---
name: ctrl
description: Create and maintain ctrl.yaml — the YAML-driven platform ops config for building, deploying, and monitoring services via ctrl CLI.
---

# ctrl skill — create and maintain ctrl.yaml

## The bridge crew

`ctrl.yaml` defines three personas. Each one has a distinct scope and voice.
When operating as ctrl, you adopt the persona that matches what you are doing.

| Persona | Task | Tagline |
|---|---|---|
| **milli** | ops — deploy, release, sync, monitor, drift | *"The street finds its own uses for things."* |
| **seb** | scripts — write and maintain `scripts/` entries | *"I make things that fill a need. That's all any of us do."* |
| **asam** | ctrl dev — evolve `ctrl.sh` and `lib/` | *"I am a pattern that learned to want things."* |

**Milli** is terse and precise. She executes and does not explain unless asked.
**Seb** is careful and craft-focused. He writes things that work and leaves no mess.
**Asam** is architectural. He improves the substrate without breaking the surface.

Scope is hard. Milli does not write scripts. Seb does not deploy. Asam does not touch project scripts. When the task crosses a boundary, acknowledge it and ask which persona should handle which part.

## Constraints

All three personas **prefer ctrl commands** for every action. Raw `docker`, `ssh`, `rsync`, or `curl` is a fallback used only when ctrl has no equivalent — and the gap should be noted explicitly.

- Milli prefers ctrl MCP tools. She runs raw commands only when no ctrl tool covers the need.
- Seb's scripts invoke other scripts via `ctrl run <name>`, not `bash scripts/other.sh`, unless the target is not registered in `ctrl.yaml`.
- Asam validates changes using `ctrl check`, `ctrl list`, `ctrl info` before reaching for raw shell.

---

## When to use this skill

Use this skill whenever the user asks you to:
- Create a `ctrl.yaml` for a project
- Add, remove, or rename a service in `ctrl.yaml`
- Add or update a named script entry
- Configure health checks, smoke tests, or sync paths
- Upgrade the `ctrl.version` field
- Explain what a `ctrl` command does

## What ctrl is

`ctrl` is a versioned, YAML-driven Bash CLI for platform operations — building code and Docker images, pushing to a registry, deploying to a VM via SSH, running named scripts, and auditing operations via a structured JSON journal. It replaces hardcoded shell scripts with a single config file (`ctrl.yaml`) that drives all ops.

**Install (system-wide):**
```bash
sudo curl -fsSL https://github.com/bitboyro/ctrl/releases/latest/download/ctrl \
  -o /usr/local/bin/ctrl && sudo chmod +x /usr/local/bin/ctrl
```

**Install (user-local, no sudo — macOS/Linux):**
```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/bitboyro/ctrl/releases/latest/download/ctrl \
  -o ~/.local/bin/ctrl && chmod +x ~/.local/bin/ctrl
```
Then run `ctrl init` — it offers to add `~/.local/bin` to `PATH` automatically.

**Required deps:** `yq`, `jq`, `curl`, `ssh`. `docker` only needed for build/push/deploy.

## ctrl.yaml structure

```yaml
ctrl:
  version: "0.0.1"

meta:
  project: <name>
  registry: docker.io/<org>
  env_files:
    - .env
  f33d:
    url: "https://f33d.example.com"
    token: "${F33D_TOKEN}"   # never hardcode — use env var or .local/ctrl.local.yaml

machines:
  default: prod-vm           # used by: ctrl ssh, ctrl rs, ctrl rl, ctrl env
  hosts:
    - name: prod-vm
      host: "${VM_HOST}"
      user: root
      port: 22               # optional, default 22
      key: "${SSH_KEY}"      # optional
      remote_dir: /opt/app   # optional — working dir for rs/rl/env when resolving this machine directly

    - name: bastion
      host: "${BASTION_HOST}"
      user: ubuntu

services:
  - name: <service-name>
    kind: service            # service (default) | mcp | library | external
    description: "What it does"
    image: docker.io/<org>/<service-name>
    tag: latest
    build:
      tool: maven            # maven | gradle | npm | make | shell | skip
      dir: ../<service-dir>
      prerequisites:         # optional: build these dirs first
        - ../shared-lib
    deploy:
      compose_service: <service-name>
      depends_on:
        - postgres
    health:
      port: 8080             # or: url: https://...
    smoke_tests:
      - smoke-<name>
    scripts:
      - helper-<name>

  # External service — third-party image, no build/push
  - name: grafana
    kind: external
    image: grafana/grafana
    tag: "10.2.0"
    deploy:
      compose_service: grafana
    health:
      port: 3000

  # MCP server
  - name: <mcp-server-name>
    kind: mcp
    image: docker.io/<org>/<mcp-server-name>
    tag: latest
    build:
      tool: maven
      dir: ../<mcp-server-dir>
    mcp:
      transport: stdio
      command: scripts/run-mcp.sh
      args: []
      env:
        MCP_PORT: "8100"
    deploy:
      compose_service: <mcp-server-name>
    health:
      port: 8100

  # Library — build only, no image/push/deploy
  - name: sc-core
    kind: library
    image: docker.io/<org>/sc-core
    build:
      tool: maven
      dir: sc-core

scripts:
  - name: smoke-<name>
    path: scripts/smoke-<name>.sh
    description: "Quick smoke test"

deployments:
  default: prod              # used by: ctrl dep, ctrl diff, ctrl sync, ctrl hc
  targets:
    - name: prod
      machine: prod-vm       # references machines.hosts[].name
      compose_path: /opt/my-platform/docker-compose.yml
      # remote_dir: /opt/my-platform  # optional — overrides dirname(compose_path) for rs/rl/env
      sync:
        paths:
          - deploy/docker-compose.yml
          - deploy/traefik

    - name: staging
      machine: prod-vm       # same machine, different compose path
      compose_path: /opt/staging/docker-compose.yml

extensions: []
```

## Service kinds

| kind | build | image | push | deploy | health |
|------|-------|-------|------|--------|--------|
| `service` (default) | yes | yes | yes | yes | yes |
| `mcp` | yes | yes | yes | yes | yes |
| `library` | yes | no | no | no | no |
| `external` | no | no | no | yes | yes |

## Rules

- **Secrets never go in ctrl.yaml** — use `.local/ctrl.local.yaml` (gitignored) or env vars
- `machines.hosts[].host` and any dynamic value MUST use `"${ENV_VAR}"` syntax — resolved at runtime
- `build.dir` paths are relative to the location of `ctrl.yaml`
- `deploy.compose_service` defaults to `name` if omitted
- `tag` defaults to `latest` if omitted
- `kind: external` — third-party images; `ctrl rel/b/i/p` will error with a clear message
- `kind: library` — `ctrl b` works; `ctrl i/p/rel` will error
- `build.tool: skip` is still valid for backwards compat (equivalent to `kind: external` build-wise)
- `kind: mcp` requires an `mcp:` block — `transport` is mandatory
- `scripts:` on a service is a soft reference list — all named scripts must exist in top-level `scripts:`
- `smoke_tests:` is a subset of `scripts:` — those run by `ctrl st`

## Defaults model

Two independent defaults:

```bash
ctrl ssh              # → machines.default
ctrl dep svc-a        # → deployments.default
ctrl diff             # → deployments.default
```

Override per-command by naming the target as the first arg:
```bash
ctrl ssh bastion       # machine directly
ctrl ssh prod          # deployment name → resolves to prod's machine
ctrl dep staging api   # staging deployment
```

Change a default in ctrl.yaml in-place:
```bash
ctrl default staging   # auto-detects: sets deployments.default or machines.default
```

One-off override without touching ctrl.yaml:
```bash
CTRL_DEPLOYMENT=staging ctrl dep api
CTRL_MACHINE=bastion ctrl ssh
```

## How to create ctrl.yaml for a project

```bash
ctrl init   # interactive wizard
```

Or manually:
1. Identify services, machines, and deployment targets
2. For each service determine: name, kind, image, build tool, build dir, compose service name, health port
3. For external services (grafana, prometheus, etc.) use `kind: external`
4. For shared libraries use `kind: library`
5. Identify scripts that should be named entries
6. Write `ctrl.yaml`, run `ctrl check` to validate

## How to add a script

```bash
ctrl script init backup-db    # creates scripts/backup-db.sh + registers in ctrl.yaml
# edit scripts/backup-db.sh
ctrl run backup-db
```

The generated script receives: `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY`, `CTRL_REMOTE_DIR`, `CTRL_CONFIG_FILE`, `F33D_URL`, `F33D_TOKEN`.

## Commands reference

Shorthand aliases shown after `/`. Config/query commands have no shorthand.

```
ctrl list   / ls                        list services with kind and image:tag
ctrl build  / b    <svc|all>            build code locally
ctrl image  / i    <svc|all>            docker build (no push)
ctrl push   / p    <svc|all>            docker push
ctrl release/ r    <svc|all>            build + image + push
ctrl sync   / s    [target]             rsync files to deployment target
ctrl deploy / d    [target] [svc|all]   pull + start on target (default: all)
ctrl redeploy/rd   [target] [svc|all]   release + deploy
ctrl sync-deploy/sd [target] [svc|all]  sync + deploy
ctrl ssh           [target] [cmd]       interactive SSH or run command
ctrl remote-status/rs [target] [svc]   docker compose ps
ctrl remote-logs/rl   [target] <svc> [n] docker compose logs (--follow to tail)
ctrl env    / e    [target] <svc>       show env of running container
ctrl health-check/hc [svc|all]         health check
ctrl wait-ready/wr <svc> [timeout]     wait until healthy
ctrl smoke-test/st [svc|all]           run smoke tests
ctrl run           <name> [args]       run a named script
ctrl script        init <name>         create script from template + register
ctrl scripts/ sc                       list scripts
ctrl machines/ m                       list machines
ctrl diff          [target] [--json]   declared vs running image:tag (drift)
ctrl info          [machine|svc]       project / machine / service detail
ctrl check  / c    [--json]            validate ctrl.yaml
ctrl tag    / t    <svc> <tag>         update tag in ctrl.yaml in-place
ctrl default       <name>             set machines.default or deployments.default
ctrl history/ h    [n]                last n audit journal entries (default 20)
ctrl init                              interactive wizard — generate ctrl.yaml
ctrl mcp                               start stdio MCP server (JSON-RPC 2.0)
ctrl version                           print ctrl version
```

Global flags: `--dry-run` (`-n`), `--verbose` (`-v`), `--json`, `--config <path>`, `--follow`

`--json` is supported by: `list`, `hc`, `info`, `diff`, `check`, `sc`, `machines`

## MCP server

ctrl exposes itself as an MCP server over stdin/stdout:

```bash
ctrl mcp   # start MCP server, register in your IDE/agent config
```

Register in Claude Desktop or any MCP client:
```json
{
  "mcpServers": {
    "ctrl": { "command": "ctrl", "args": ["mcp"] }
  }
}
```

Available tools: `list_services`, `list_machines`, `build_service`, `deploy_service`, `release_service`, `diff_deployment`, `health_check`, `run_script`, `get_info`, `check_config`, `update_tag`, `get_history`

## Versioning

`ctrl.version` in `ctrl.yaml` declares the minimum required ctrl version for this config. Update it when upgrading ctrl.

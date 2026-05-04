# ctrl

YAML-driven platform operations CLI. One config file (`ctrl.yaml`) drives building Docker images,
pushing to a registry, deploying to a VM over SSH, running named scripts, and auditing everything
to a structured journal.

## Install

**System-wide (Linux/macOS):**
```bash
sudo curl -fsSL https://github.com/bitboyro/ctrl/releases/latest/download/ctrl \
  -o /usr/local/bin/ctrl && sudo chmod +x /usr/local/bin/ctrl
```

**User-local (no sudo):**
```bash
mkdir -p ~/.local/bin
curl -fsSL https://github.com/bitboyro/ctrl/releases/latest/download/ctrl \
  -o ~/.local/bin/ctrl && chmod +x ~/.local/bin/ctrl
```
Then run `ctrl init` — it offers to add `~/.local/bin` to `PATH` automatically.

**Required:** `yq`, `jq`, `curl`, `ssh`. `docker` only needed for build/push/deploy.

## Quick start

```bash
ctrl init           # interactive wizard — generates ctrl.yaml
ctrl check          # validate the config
ctrl list           # show services with kind and image:tag
```

## ctrl.yaml

```yaml
ctrl:
  version: "0.0.1"

meta:
  project: my-platform
  registry: docker.io/myorg
  env_files:
    - .env            # sourced before every command

machines:
  default: prod-vm
  hosts:
    - name: prod-vm
      host: "${VM_HOST}"    # always use env vars — never hardcode
      user: root
      port: 22

services:
  - name: api
    image: docker.io/myorg/api
    tag: latest
    build:
      tool: maven
      dir: ../api
    deploy:
      compose_service: api
    health:
      port: 8080
    smoke_tests:
      - smoke-api

  # Third-party image — no build/push, just deploy + health
  - name: grafana
    kind: external
    image: grafana/grafana
    tag: "10.2.0"
    deploy:
      compose_service: grafana
    health:
      port: 3000

scripts:
  - name: smoke-api
    path: scripts/smoke-api.sh
    description: "Quick API smoke test"

deployments:
  default: prod
  targets:
    - name: prod
      machine: prod-vm
      compose_path: /opt/scaffold/docker-compose.yml
      sync:
        paths:
          - scaffold/docker-compose.yml
          - scaffold/.env
```

Secrets never go in `ctrl.yaml`. Use env vars (`"${MY_SECRET}"`) or a gitignored
`.local/ctrl.local.yaml` for per-environment overrides.

## Build pipeline

```bash
ctrl build api          # compile code
ctrl image api          # docker build (no push)
ctrl push api           # docker push
ctrl release api        # build + image + push (shorthand: ctrl r api)
ctrl release all        # release every service
```

## Deploy pipeline

```bash
ctrl deploy             # deploy all services to default target
ctrl deploy api         # deploy one service
ctrl deploy staging api # deploy to a named target
ctrl sync               # rsync files to the deployment target
ctrl sync-deploy        # sync + deploy in one step (shorthand: ctrl sd)
ctrl redeploy api       # release + deploy (shorthand: ctrl rd api)
```

## Remote & SSH

```bash
ctrl ssh                # interactive SSH to default machine
ctrl ssh bastion        # SSH to a named machine
ctrl ssh prod           # SSH to the machine of the prod deployment
ctrl ssh prod -- df -h  # run a remote command

ctrl remote-status      # docker compose ps (shorthand: ctrl rs)
ctrl remote-logs api    # docker compose logs api (shorthand: ctrl rl api)
ctrl remote-logs api --follow   # tail logs
ctrl env api            # show env vars of running container (shorthand: ctrl e api)
```

## Health & smoke tests

```bash
ctrl health-check       # health-check all services (shorthand: ctrl hc)
ctrl health-check api
ctrl wait-ready api 60  # poll until healthy, 60s timeout (shorthand: ctrl wr)
ctrl smoke-test api     # run smoke_tests scripts for a service (shorthand: ctrl st)
```

## Scripts

```bash
ctrl script init backup-db      # scaffold scripts/backup-db.sh + register in ctrl.yaml
ctrl run backup-db              # run a named script
ctrl scripts                    # list scripts (shorthand: ctrl sc)
```

Scripts receive `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY`, `CTRL_REMOTE_DIR`,
`F33D_URL`, and `F33D_TOKEN` as environment variables.

## Config & info

```bash
ctrl check              # validate ctrl.yaml (--json for machine-readable)
ctrl info               # project summary
ctrl info prod-vm       # machine detail
ctrl info api           # service detail
ctrl machines           # list machines with deployment count (shorthand: ctrl m)
ctrl diff               # declared vs running image:tag on default target
ctrl diff staging       # drift on a named target
ctrl tag api v1.2.3     # update tag in ctrl.yaml in-place (shorthand: ctrl t)
ctrl default staging    # set deployments.default in ctrl.yaml
```

## Defaults and overrides

Commands pick up defaults from `ctrl.yaml`:

```bash
ctrl ssh           # → machines.default
ctrl deploy        # → deployments.default
```

Override for one command without touching the file:

```bash
CTRL_MACHINE=bastion ctrl ssh
CTRL_DEPLOYMENT=staging ctrl deploy api
```

Change the default permanently:

```bash
ctrl default staging    # auto-detects machine vs deployment
```

## Global flags

| Flag | Short | Effect |
|------|-------|--------|
| `--dry-run` | `-n` | Print commands, no execution |
| `--verbose` | `-v` | Extra debug output |
| `--json` | | JSON output for `list`, `hc`, `info`, `diff`, `check`, `sc`, `machines` |
| `--config <path>` | | Override `ctrl.yaml` location |
| `--follow` | | Tail logs (with `rl`) |

## MCP server

ctrl exposes itself as an MCP server over stdin/stdout for use with Claude or any MCP client:

```bash
ctrl mcp
```

Register in Claude Desktop:
```json
{
  "mcpServers": {
    "ctrl": { "command": "ctrl", "args": ["mcp"] }
  }
}
```

Available tools: `list_services`, `list_machines`, `build_service`, `deploy_service`,
`release_service`, `diff_deployment`, `health_check`, `run_script`, `get_info`,
`check_config`, `update_tag`, `get_history`

## Audit journal

Every operation is logged to `~/.local/share/ctrl/journal.jsonl`:

```bash
ctrl history        # last 20 entries (shorthand: ctrl h)
ctrl history 50
```

## Service kinds

| kind | build | push | deploy | health |
|------|-------|------|--------|--------|
| `service` (default) | yes | yes | yes | yes |
| `mcp` | yes | yes | yes | yes |
| `library` | yes | no | no | no |
| `external` | no | no | yes | yes |

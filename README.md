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

## Dependencies

| Tool | Required | Purpose |
|------|----------|---------|
| `yq` | always | YAML parsing |
| `jq` | always | JSON processing |
| `curl` | always | health checks, GitLab API, f33d notifications |
| `ssh` | always | remote access (`ssh`, `rs`, `rl`, `env`) |
| `docker` | build/push/deploy/probe | image build, push, compose ops, and running ctrl-tools |
| `rsync` | sync commands | file sync to deployment targets |
| `nc` | `ctrl probe --tcp` | TCP connectivity checks (pre-installed on most systems) |
| `tcpdump` | `ctrl probe sniff --host` | host-level packet capture (optional; container mode uses ctrl-tools) |
| `sshpass` | optional | password-based SSH machines |

Run `ctrl doctor` to verify all deps and get install hints for anything missing.

## Quick start

```bash
ctrl init           # interactive wizard — generates ctrl.yaml
ctrl check          # validate the config
ctrl list           # show services with kind and image:tag
```

## Shell completion

```bash
# bash — add to ~/.bashrc
eval "$(ctrl completion bash)"

# zsh — add to ~/.zshrc
eval "$(ctrl completion zsh)"
# or install as a fpath function:
ctrl completion zsh > "${fpath[1]}/_ctrl"
```

## ctrl.yaml

```yaml
ctrl:
  version: "0.2.1"        # pinned ctrl version; `ctrl check` warns on mismatch

meta:
  project: my-platform
  registry: docker.io/myorg
  env_files:
    - .env                # sourced before every command
    # .local/secrets.env is auto-loaded when present — no need to list it

machines:
  default: prod-vm
  hosts:
    - name: prod-vm
      host: "${VM_HOST}"            # always use env vars — never hardcode
      user: root
      port: 22
      cwd: /root                     # optional interactive SSH start dir for `ctrl ssh prod-vm`
      # password: "${VM_PASSWORD}"  # optional — requires sshpass

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
      compose_path: /opt/my-platform/docker-compose.yml
      # cwd: /opt/my-platform        # optional override for `ctrl ssh prod`
      sync:
        paths:
          - deploy/docker-compose.yml
          - deploy/.env
```

Secrets never go in `ctrl.yaml`. Use env vars (`"${MY_SECRET}"`) or a gitignored
`.local/ctrl.local.yaml` for per-environment overrides.

### `.local/` convention

`ctrl init` creates a gitignored `.local/` directory at the project root with:

```
.local/
├── .gitignore           # contains: *
└── secrets.env.example  # template for local secret values
```

Drop your secrets in `.local/secrets.env` — ctrl auto-loads it whether or not
it's listed in `meta.env_files`. When `.local/` exists, the audit journal is
written to `.local/journal/journal.jsonl` (project-local), otherwise it falls
back to `~/.local/share/ctrl/journal.jsonl`.

### Password-based SSH

If a machine cannot use key auth, declare a `password:` field that resolves
from `.local/secrets.env`:

```yaml
machines:
  hosts:
    - name: legacy-box
      host: "${LEGACY_HOST}"
      user: root
      password: "${LEGACY_PASSWORD}"   # resolved from .local/secrets.env
```

This requires `sshpass` on the local machine
(`brew install sshpass` / `apt-get install sshpass`). Password values are
redacted from `--dry-run` output and never appear in logs.

### Interactive SSH Start Directory

`ctrl ssh` can now start in a configurable directory that is separate from the
deployment compose directory:

```yaml
machines:
  hosts:
    - name: legacy-box
      host: "${LEGACY_HOST}"
      user: root
      cwd: /root

deployments:
  targets:
    - name: legacy-prod
      machine: legacy-box
      compose_path: /srv/legacy/docker-compose.yml
      cwd: /srv/legacy
```

- `machines.hosts[].cwd` sets the default interactive start dir for `ctrl ssh <machine>`.
- `deployments.targets[].cwd` overrides that for `ctrl ssh <deployment>`.
- Compose-driven commands such as `ctrl deploy`, `ctrl rs`, `ctrl rl`, and `ctrl env` still use `dirname(compose_path)`.

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
ctrl health-check       # health-check all health-configured, non-library services (shorthand: ctrl hc)
ctrl health-check api
ctrl wait-ready api 60  # poll until healthy, 60s timeout (shorthand: ctrl wr)
ctrl smoke-test api     # run smoke_tests scripts for a service (shorthand: ctrl st)
```

## Scripts

```bash
ctrl script init backup-db      # create scripts/backup-db.sh + register in ctrl.yaml
ctrl run backup-db              # run a named script
ctrl scripts                    # list scripts (shorthand: ctrl sc)
ctrl scripts --tag deploy       # filter by tag
```

Generated scripts follow a structured template — path detection (`SCRIPT_DIR`,
`CTRL_ROOT`), deployment context detection (`DEPLOYMENT_DIR`, `DEPLOYMENT_NAME`
when placed under `<deployment>/ops/`), automatic core library loading with
fallback stubs, `--help` / `--dry-run` / `--output` parsing, an entry-point
guard (sourceable or executable), and a cleanup trap.

To customize: drop your own template at `scripts/templates/ctrl-script.sh` in
the project root — `ctrl script init` will use it instead of the built-in
template (with `__NAME__` substituted).

Scripts can carry optional `tags` for grouping:

```yaml
scripts:
  - name: smoke-api
    path: scripts/smoke-api.sh
    tags: [smoke, deploy]
```

Scripts receive `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY`,
`CTRL_REMOTE_DIR`, `CTRL_CONFIG_FILE`, `CTRL_MACHINE_NAME`, `CTRL_DEPLOY_NAME`,
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

## Help

Use the built-in help when you need the exact flags, config fields, or examples
for a single command:

```bash
ctrl help                 # top-level grouped help
ctrl help deploy          # command-specific help
ctrl help cp              # copy command help with examples
```

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

## Versioning

`ctrl version` prints the running version. Pin a required version in your
`ctrl.yaml`:

```yaml
ctrl:
  version: "0.2.1"
```

`ctrl check` warns when the running ctrl version doesn't match the declared
one. Install a specific release by passing the tag to the installer:

```bash
./install.sh v0.2.1     # specific version
./install.sh            # latest from main
```

Projects can vendor their own ctrl at `vendor/ctrl/ctrl.sh` or `.ctrl/ctrl.sh`
next to `ctrl.yaml`; downstream wrappers can locate it via
`ctrl_find_vendored`.

## Audit journal

Every operation is logged to `.local/journal/journal.jsonl` (when a `.local/`
directory exists at the project root) or `~/.local/share/ctrl/journal.jsonl`
otherwise:

```bash
ctrl history        # last 20 entries (shorthand: ctrl h)
ctrl history 50
```

## File copy

```bash
ctrl cp ./build/api.jar prod:/srv/api/          # local -> remote
ctrl cp prod:/var/log/app.log ./tmp/app.log     # remote -> local
ctrl cp --exclude node_modules ./site/ prod:/srv/site/
```

`ctrl cp` uses `rsync` semantics for local/local, local/remote, remote/local,
and remote/remote transfers. Remote endpoints use `machine-name:/path` and
reuse the SSH settings from `machines.hosts[]` in `ctrl.yaml`.

## Diagnostics

Packet capture is exposed as `ctrl probe sniff`. There is no standalone
`ctrl sniff`, `ctrl capture`, or `ctrl bench` command in the current release.

```bash
ctrl ping api                          # HTTP ping api's health URL (5 times, with latency)
ctrl ping api --n 10                   # 10 pings
ctrl ping prod-vm                      # TCP ping machine on port 22

ctrl call api /actuator/info           # GET request — base URL from health.port
ctrl call api /users --method POST --body '{"name":"test"}'
# JWT_TOKEN env var injected automatically if set

ctrl probe api                         # HTTP connectivity check
ctrl probe api --tcp                   # TCP check
ctrl probe prod-vm --port 5432 --tcp   # check postgres port on a machine

ctrl probe sniff api                   # live tcpdump via ctrl-tools container
ctrl probe sniff api --filter 'port 5432' --save  # save to .local/captures/
ctrl probe sniff prod api --duration 60           # run capture on remote target
ctrl probe sniff api --host            # tcpdump on host machine instead of container

ctrl probe shell                       # interactive ctrl-tools shell
ctrl probe shell --network api         # joined to api's Docker network
ctrl probe shell --mount ./logs:/data  # with host dir mounted

ctrl doctor                            # check all deps, show install hints
ctrl doctor --install                  # auto-install missing tools
```

The `ctrl probe sniff` and `ctrl probe shell` commands use the
`ghcr.io/bitboyro/ctrl-tools` image — pulled on demand, never built locally.
It bundles `tcpdump`, `tshark`, `curl`, `nc`, `nmap`, `jq`, `python3`, and `scanos`.

## Workflows

**First deploy:**
```bash
ctrl init            # generate ctrl.yaml
ctrl check           # validate
ctrl release api     # build + image + push
ctrl sync            # rsync compose files to the server
ctrl deploy api      # pull + start on the server
ctrl hc api          # verify health
```

**Daily ops:**
```bash
ctrl diff            # check for image drift before deploying
ctrl release api     # build new image
ctrl deploy api      # deploy to default target
ctrl hc api          # verify
ctrl history 5       # see audit trail
```

**Debugging a live service:**
```bash
ctrl rs              # docker compose ps
ctrl rl api --follow # tail logs
ctrl env api         # inspect container env
ctrl probe sniff api --filter 'port 5432'  # watch database traffic
ctrl ssh             # drop into the machine
```

## Troubleshooting

**Missing dependency**
```
error  Required command not found: yq
```
Run `ctrl doctor` for install hints, or `ctrl doctor --install` to auto-install.

**Env var not set**
```
error  Machine 'prod-vm' has no host defined
```
Check `ctrl doctor` for unset vars. Declare them in `.local/secrets.env` or export before running ctrl.

**SSH key not found / permission denied**
Verify `machines.hosts[].key` resolves correctly: `ctrl info prod-vm`. Ensure the key path is correct and the file is readable.

**ctrl.yaml version mismatch**
```
warn  ctrl version (0.2.1) differs from ctrl.version declared in ctrl.yaml (0.2.0)
```
Update `ctrl.version` in `ctrl.yaml` to match `ctrl version`, or upgrade ctrl.

**`ctrl probe sniff` fails: container can't see traffic**
The service container may be on a bridge network that doesn't allow raw capture. Try `--host` mode, or run the probe from the remote machine: `ctrl probe sniff prod api`.

## Service kinds

| kind | build | push | deploy | health |
|------|-------|------|--------|--------|
| `service` (default) | yes | yes | yes | yes |
| `mcp` | yes | yes | yes | yes |
| `library` | yes | no | no | no |
| `external` | no | no | yes | yes |

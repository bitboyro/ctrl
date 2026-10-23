# ctrl

YAML-driven platform operations CLI. One config file (`ctrl.yaml`) drives building Docker images,
pushing to a registry, deploying to a VM over SSH, and auditing everything to a structured journal.

One command runs every script — yours, and a bundled library of useful ones (screen recording,
Docker install, sharing a folder with a QR code, server hardening, …) — on this machine or on any
set of hosts in parallel:

```bash
ctrl run                              # everything you can run
ctrl run rec --gif                    # record the screen → small mp4 + gif
ctrl run install-docker --on staging  # set up a VM
ctrl run sysinfo --on all             # every machine at once
```

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
| `bash` | always | 3.2+ (stock macOS works); remote hosts need bash for `run --on` |
| `yq` | always | YAML parsing — mikefarah yq v4.18+ (not the pip package) |
| `jq` | always | JSON processing |
| `curl` | always | health checks, downloads |
| `ssh` | always | remote access (`ssh`, `rs`, `rl`, `env`, `run --on`) |
| `docker` | build/push/deploy | image build, push, compose ops |
| `rsync` | sync, cp | file sync to deployment targets |
| `nc` | `hc --tcp` | TCP checks |
| `sshpass` | optional | password-based SSH machines |

`ctrl doctor` checks all of them for your platform (macOS/Linux, amd64/arm64,
brew/apt/dnf/apk) and prints the exact install command; `ctrl doctor --install`
runs it. Tools that only a script needs are checked by `ctrl run <name> --check`.

## Quick start

```bash
ctrl init           # interactive wizard — generates ctrl.yaml
ctrl doctor         # tools, env vars, config
ctrl list           # services with kind and image:tag
ctrl run            # scripts: your project's and the bundled library
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
  version: "0.4.1"        # pinned ctrl version; `ctrl check` warns on mismatch

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
      remote_dir: /opt/my-platform  # optional — working dir for rs/rl/env when resolving this machine directly
      tags: [web]                   # optional — `ctrl run <script> --on @web`
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

scripts:                          # optional — scripts/<name>.sh is found without an entry
  - name: smoke-api
    path: scripts/smoke-api.sh
    description: "Quick API smoke test"

deployments:
  default: prod
  targets:
    - name: prod
      machine: prod-vm
      compose_path: /opt/my-platform/docker-compose.yml
      # remote_dir: /opt/my-platform  # optional — overrides dirname(compose_path) for rs/rl/env
      # cwd: /opt/my-platform         # optional override for `ctrl ssh prod`
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

This requires `sshpass` on the local machine (`ctrl doctor` shows the
install command for your platform). Password values are
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

### Remote working directory

`ctrl rs`, `ctrl rl`, `ctrl env`, and `ctrl deploy` all `cd` into a resolved remote working directory before running Docker Compose. Resolution order (first match wins):

1. `deployments.targets[].remote_dir` — explicit override on the deployment target
2. `dirname(deployments.targets[].compose_path)` — derived automatically when `compose_path` is set
3. `machines.hosts[].remote_dir` — used when resolving a machine directly (no deployment context)
4. `$CTRL_META_REMOTE_DIR` env var — process-level override
5. `/opt/app` — hardcoded default

In most setups `compose_path` is enough. Set `remote_dir` on a machine when `ctrl rs` / `ctrl rl` should work correctly even without going through a named deployment target.

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
ctrl deploy                   # deploy all services to default target
ctrl deploy api               # deploy one service
ctrl deploy staging api       # deploy to a named target
ctrl deploy --release api     # build + image + push first
ctrl deploy --sync            # rsync the target's sync.paths first
ctrl sync                     # rsync only
ctrl diff                     # declared vs running image:tag
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

## Health

```bash
ctrl hc                       # every service with health config (HTTP)
ctrl hc api                   # one service
ctrl hc api --wait 60         # poll until healthy, up to 60 s
ctrl hc api --count 10        # latency stats: min/avg/max/loss
ctrl hc prod-vm               # machine: TCP on its SSH port
ctrl hc prod-vm --port 5432   # is postgres reachable?
ctrl run smoke api            # run the service's smoke_tests scripts
```

## Scripts — `ctrl run`

`ctrl run` is the one command for every script. A name resolves, first match wins, to:

1. a `ctrl.yaml` `scripts[]` entry with a `path`
2. `scripts/<name>.sh` in the project (auto-discovered, no entry needed)
3. a bundled script shipped inside ctrl

The same small set of modifiers works on every script:

| Modifier | Effect |
|----------|--------|
| `--on <where>` | `local` · a deployment or machine · `a,b` · `@tag` · `all` — several targets run in parallel with host-prefixed output and a per-host summary; exit code is non-zero if any fails |
| `--check` | pre-flight only (OS, tools, env vars, sudo) on every host |
| `--show` | header and source; for a project copy of a bundled script, the diff against the bundled version |
| `--own` | copy a bundled script into `scripts/` — edit it; `ctrl run <name>` now uses your copy |
| `-n`, `--dry-run` | print what would run; bundled scripts print their exact underlying commands |
| `--yes` | confirm scripts that change the system with sudo |

Everything else after the name goes to the script, and everything after `--` always does.

```bash
ctrl run                                   # list, grouped; --tag <t> filters, --json
ctrl run backup-db                         # a project script
ctrl run backup-db --on prod               # stream it to prod and run it there
ctrl run cleanup --on @web --check         # would it run on every web host?
ctrl run rec --own                         # make the bundled recorder yours
ctrl run new-script cleanup                # scaffold scripts/cleanup.sh
```

Remote runs stream the script over SSH (`bash -s`); nothing is left on the host.
`@env` variables set locally travel on stdin, never on a command line.

### Script headers

Metadata lives in the script itself (first 60 lines). A `ctrl.yaml` entry with
the same name overrides any of it.

```bash
#!/usr/bin/env bash
# @description: Nightly database backup to S3
# @group: ops
# @requires: pg_dump rclone          # checked before running, locally and on every --on host
# @env: S3_BUCKET                    # must be set; forwarded to --on hosts
# @env-optional: RCLONE_FLAGS        # forwarded when set
# @os: linux                         # linux and/or darwin
# @sudo: no                          # yes → confirmation (or --yes) first
# @remote: yes                       # no → refuses --on
# @dry-run: no                       # yes → runs under -n with CTRL_DRY_RUN=1
# @tags: backup nightly
```

A missing tool is reported with the install command for that host's platform.

Scripts receive `CTRL_PROJECT`, `CTRL_PROJECT_DIR`, `CTRL_CONFIG_FILE`,
`CTRL_CONFIG_MERGED` (with `.local/` overrides), `CTRL_SSH_HOST`, `CTRL_REGISTRY`,
`CTRL_REMOTE_DIR`, `CTRL_MACHINE_NAME`, `CTRL_DEPLOY_NAME`, `CTRL_OS`,
`CTRL_ARCH`, `CTRL_PKG`, `CTRL_DRY_RUN`, `CTRL_YES`, `CTRL_BIN`, `F33D_URL` and
`F33D_TOKEN`; remote runs also get `CTRL_REMOTE=1`. Hooks (`hooks.pre` /
`hooks.post` in `ctrl.yaml`) still run around local runs.

`ctrl run new-script <name>` writes a structured template (path and
deployment-context detection, `--help` / `--dry-run` parsing, cleanup trap).
Drop your own template at `scripts/templates/ctrl-script.sh` to replace it
(`__NAME__` is substituted).

### The bundled library

Every bundled script works with no arguments (settings are inferred), prints its
exact commands under `-n`, asks before changing the system, and runs remotely
with `--on` unless it needs your desktop. `ctrl run <name> --help` shows its flags.

| Group | Script | What it does |
|-------|--------|--------------|
| dev | `lint` | Detects file types and runs the right linter for each: shellcheck (honours `.shellcheckrc`), hadolint, yamllint (or a yq parse), actionlint, jq, ruff, eslint, gofmt/go vet, `ctrl check`; `--changed` (only files changed vs main), `--fix`, `--only`, `--list` shows missing linters with an install hint |
| | `loc` | Lines of code, comments and blanks per language, `--by dir`, `--by file --top N`, `--json`; pure awk, no dependencies |
| | `churn` | Git activity: lines added/removed `--by author`, `--by file`, or `--by hotspot` (changes × size) over `--since '30 days'` |
| media | `rec` | Screen → small mp4 (15 fps, half scale, CRF 30 ≈ 5 MB/min); screen detected via avfoundation, x11grab or wf-recorder; `--gif`, `--audio`, `--region`, `--time` |
| | `gif` | Video → sharp GIF with a two-pass palette |
| | `shrink` | Re-encode to fit a size: `--to 8M` |
| | `snap` | Screenshot (full, `--region`, `--window`), `--clip` to clipboard |
| share | `share` | Serve a file/folder on the LAN with a terminal QR code; `--tunnel` for a public URL |
| | `qr` | QR code for text, URLs, or `--wifi SSID --password P` |
| setup | `install-docker` | Docker Engine + compose from download.docker.com, repo key fingerprint verified; Colima on macOS |
| | `add-swap` | Swap file sized from RAM, persisted, low swappiness |
| | `harden-ssh` | Key-only SSH with lock-out guards and `sshd -t` validation |
| | `ufw-basics` | Deny incoming, allow the SSH port you are on plus `--allow` ports |
| | `install-tailscale` | Signed package repo; joins with `TS_AUTHKEY` passed as a file |
| | `timezone` | Show/set the timezone; no argument infers it from your IP |
| docker | `dsh` | Fuzzy-pick a container and shell into it |
| | `dtop` | CPU/memory/network/IO per container |
| | `dclean` | Show what can be reclaimed, then prune (asks) |
| network | `ports` | What listens where, and which process; `--kill PORT` |
| | `myip` | Local and public IP with location |
| | `certs` | TLS expiry/issuer/names — defaults to every https endpoint in `ctrl.yaml` |
| | `sniff` | tcpdump on a service's container network (ctrl-tools image), `--host`, `--save` |
| | `toolbox` | Shell in the ctrl-tools container on a service's network |
| | `api-call` | REST call to a service; `JWT_TOKEN` sent as Bearer, kept out of `ps` |
| system | `sysinfo` | One-screen machine summary; `--short` for one line per host |
| | `hogs` | Biggest folders, hungriest processes, fullest disks |
| ci | `gitlab-info` | GitLab project details (`GITLAB_TOKEN`) |
| | `gitlab-runner` | Install (SHA256-verified) and register a runner |
| project | `smoke` | Run `services[].smoke_tests` |
| meta | `new-script` | Scaffold a project script |

## Config & info

```bash
ctrl check              # validate ctrl.yaml, names, script headers (--json)
ctrl info               # project summary
ctrl info prod-vm       # machine detail
ctrl info api           # service detail
ctrl list machines      # machines with deployment count
ctrl set tag api v1.2.3 # update a service tag in ctrl.yaml
ctrl set default staging
ctrl doctor prod        # check a host: OS, docker, compose v2, rsync, sudo
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
ctrl set default staging    # auto-detects machine vs deployment
```

## Global flags

| Flag | Short | Effect |
|------|-------|--------|
| `--dry-run` | `-n` | Print commands, no execution |
| `--verbose` | `-v` | Extra debug output |
| `--json` | | JSON output for `list`, `info`, `diff`, `check`, `run` (listing) |
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


## Upgrade

```bash
ctrl upgrade
```

Fetches the latest VERSION from GitHub, renders an ANSI-colored CHANGELOG diff between your
current version and the new one (green for Added, red for Breaking, yellow for Changed/Fixed),
then replaces the binary atomically after confirmation.

Use `CTRL_DRY_RUN=1 ctrl upgrade` to preview the changelog without replacing the binary.

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

**Tools:** `list_services`, `list_machines`, `get_info`, `check_config`,
`build_service`, `release_service`, `deploy_service`, `diff_deployment`,
`health_check`, `run_list`, `run` (`name`, `args`, `on`, `check`, `dry_run`,
`yes`), `update_tag`, `get_history`. Every parameter is validated; scripts that
use sudo need `yes: true`. A failing tool returns `{"error": …}` — the server
keeps running. The server also works outside a project (bundled scripts).

## Versioning

`ctrl version` prints the running version. Pin a required version in your
`ctrl.yaml`:

```yaml
ctrl:
  version: "0.4.1"
```

`ctrl check` warns when the running ctrl version doesn't match the declared
one. Install a specific release by passing the tag to the installer:

```bash
./install.sh v0.4.1     # specific version
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

## Migrating from 0.3

Removed commands print their replacement when you use them.

| 0.3 | 0.4 |
|-----|-----|
| `ctrl cpr <s> [target]` | `ctrl run <s> --on <target>` |
| `ctrl scripts` / `sc` | `ctrl run` |
| `ctrl script init <n>` | `ctrl run new-script <n>` |
| `ctrl redeploy` / `rd` | `ctrl deploy --release` |
| `ctrl sync-deploy` / `sd` | `ctrl deploy --sync` |
| `ctrl wait-ready <s> N` | `ctrl hc <s> --wait N` |
| `ctrl ping <x> --n N` | `ctrl hc <x> --count N` |
| `ctrl probe <x> [--tcp] [--port N]` | `ctrl hc <x> [--tcp] [--port N]` |
| `ctrl probe sniff <s>` | `ctrl run sniff <s>` (`--on <target>` for a remote host) |
| `ctrl probe shell` | `ctrl run toolbox` |
| `ctrl call <s> <path>` | `ctrl run api-call <s> <path>` |
| `ctrl smoke-test` / `st` | `ctrl run smoke` |
| `ctrl machines` / `m` | `ctrl list machines` |
| `ctrl tag <s> <t>` | `ctrl set tag <s> <t>` |
| `ctrl default <n>` | `ctrl set default <n>` |
| `ctrl gitlab-project-info` | `ctrl run gitlab-info` |
| `ctrl gitlab-runner-deploy` | `ctrl run gitlab-runner --on <target>` (token: `GITLAB_RUNNER_TOKEN`) |

Also: names in `ctrl.yaml` (services, machines, deployments, scripts, compose
services, tags) must be plain tokens — letters, digits, `_`, `.`, `-`; extensions
must be `.sh` files inside the project and define `ctrl_ext_cmd_<name>`
(`ctrl_cmd_<name>` still works).

## Workflows

**First deploy:**
```bash
ctrl init            # generate ctrl.yaml
ctrl check           # validate
ctrl run install-docker --on prod   # fresh VM? set it up
ctrl deploy --release --sync api    # build, push, sync compose files, start
ctrl hc api --wait 60               # verify health
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
ctrl run sniff api --on prod --filter 'port 5432'  # watch database traffic
ctrl run dtop --on prod                           # container resources
ctrl ssh             # drop into the machine
```

## Troubleshooting

**Missing dependency**
```
error  Required command not found: yq
```
Run `ctrl doctor` for the install command on your platform, or `ctrl doctor --install`.

**Env var not set**
```
error  Machine 'prod-vm' has no host defined
```
Check `ctrl doctor` for unset vars. Declare them in `.local/secrets.env` or export before running ctrl.

**SSH key not found / permission denied**
Verify `machines.hosts[].key` resolves correctly: `ctrl info prod-vm`. Ensure the key path is correct and the file is readable.

**ctrl.yaml version mismatch**
```
warn  ctrl version (0.3.0) differs from ctrl.version declared in ctrl.yaml (0.2.5)
```
Update `ctrl.version` in `ctrl.yaml` to match `ctrl version`, or upgrade ctrl.

**`ctrl run sniff` fails: container can't see traffic**
The service container may be on a bridge network that doesn't allow raw capture. Try `--host`, or run it on the host itself: `ctrl run sniff api --on prod`.

**A script refuses to run**
`ctrl run <name> --check [--on …]` lists every unmet requirement (OS, tools with install commands, env vars, sudo) without running anything.

## Service kinds

| kind | build | push | deploy | health |
|------|-------|------|--------|--------|
| `service` (default) | yes | yes | yes | yes |
| `mcp` | yes | yes | yes | yes |
| `library` | yes | no | no | no |
| `external` | no | no | yes | yes |

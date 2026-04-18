# ctrl skill — create and maintain ctrl.yaml

## The bridge crew

`ctrl.yaml` defines three personas. Each one has a distinct scope and voice.
When operating as ctrl, you adopt the persona that matches what you are doing.

| Persona | Task | Tagline |
|---|---|---|
| **milli** | ops — deploy, release, sync, monitor | *"The street finds its own uses for things."* |
| **seb** | scripts — write and maintain `scripts/` entries | *"I make things that fill a need. That's all any of us do."* |
| **masamune** | ctrl dev — evolve `ctrl.sh` and `lib/` | *"I am a pattern that learned to want things."* |

**Milli** is terse and precise. She executes and does not explain unless asked.
**Seb** is careful and craft-focused. He writes things that work and leaves no mess.
**Masamune** is architectural. He improves the substrate without breaking the surface.

Scope is hard. Milli does not write scripts. Seb does not deploy. Masamune does not touch project scripts. When the task crosses a boundary, acknowledge it and ask which persona should handle which part.

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

Install: `curl -fsSL https://raw.githubusercontent.com/bitboyro/ctrl/refs/heads/main/install.sh | bash`

Or with `--init` to generate a `ctrl.yaml` on the spot:
`curl -fsSL .../install.sh | bash -s -- --init`

## ctrl.yaml structure

```yaml
ctrl:
  version: "0.1"

meta:
  project: <name>
  registry: docker.io/<org>
  ssh_host: "${VM_HOST}"     # env var reference — resolved at runtime
  ssh_user: root
  compose_path: /opt/scaffold/docker-compose.yml
  env_files:
    - .env

services:
  - name: <service-name>
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
  - name: smoke-<name>
    path: scripts/smoke-<name>.sh
    description: "Quick smoke test"

deployments:
  default: prod
  targets:
    - name: prod
      ssh_host: "${VM_HOST}"
      compose_path: /opt/scaffold/docker-compose.yml
      sync:
        paths:
          - scaffold/docker-compose.yml
          - scaffold/traefik
    # - name: staging
    #   ssh_host: "${STAGING_HOST}"

extensions: []
```

## Rules

- **Secrets never go in ctrl.yaml** — use `.local/ctrl.local.yaml` (gitignored) or env vars
- `meta.ssh_host` and any dynamic value MUST use `"${ENV_VAR}"` syntax — ctrl resolves via envsubst
- `build.dir` paths are relative to the location of `ctrl.yaml`
- `deploy.compose_service` defaults to `name` if omitted
- `tag` defaults to `latest` if omitted
- `build.tool: skip` means the service has no local build step (e.g. third-party images)
- `build.prerequisites` is a list of directories that must be built (maven install) before this service

## How to create ctrl.yaml for a project

1. Identify the project's services (from docker-compose.yml, Dockerfiles, or the user)
2. For each service determine: name, image, build tool, build dir, compose service name, health port
3. Identify any shared libraries that must be built first (add as `prerequisites`)
4. Identify scripts that already exist and should be named entries
5. Identify which files should be synced to the VM
6. Write the `ctrl.yaml` in the project root

## How to add a service

Add an entry to `services:` with at minimum: `name`, `image`, `build.tool`, `build.dir`, `deploy.compose_service`.

## How to add a script

Add an entry to `scripts:` with `name`, `path`, and `description`. The script receives these env vars: `CTRL_PROJECT`, `CTRL_SSH_HOST`, `CTRL_REGISTRY`, `CTRL_REMOTE_DIR`.

## Commands reference

Short aliases are listed after `/`.

```
ctrl list / ls                         list services with image:tag
ctrl build / b    <svc|all>            build code locally
ctrl image / i    <svc|all>            docker build (no push)
ctrl push  / pu   <svc|all>            docker push
ctrl rel          <svc|all>            build + image + push
ctrl sync         [target]             rsync files to deployment target
ctrl dep          [target] [svc|all]   pull + start on target (default: all)
ctrl rdep         [target] [svc|all]   rel + dep
ctrl sdep         [target] [svc|all]   sync + dep
ctrl ssh          [target] [cmd]       interactive SSH or run command
ctrl rs           [target] [svc]       remote status (docker compose ps)
ctrl rl           [target] <svc> [n]   remote logs (--follow to tail)
ctrl insp         [target] <svc>       show env of running container
ctrl hc           [svc|all]            health check (/actuator/health)
ctrl wr           <svc> [timeout]      wait until healthy
ctrl st           [svc|all]            run smoke tests
ctrl run          <name> [args]        run a named script
ctrl sc                                list scripts
ctrl hist         [n]                  show audit journal (default 20)
ctrl plan                              dry-run mode
ctrl version                           print ctrl version
```

Global flags: `--dry-run`, `--verbose`, `--config <path>`, `--follow`

`[target]` is a deployment name from `deployments.targets[].name` in ctrl.yaml.
When omitted, `deployments.default` is used.

## Versioning

When upgrading ctrl, update `ctrl.version` in `ctrl.yaml` to the new minimum required version.

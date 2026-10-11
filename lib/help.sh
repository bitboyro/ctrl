#!/usr/bin/env bash
# help.sh — top-level help, per-command help, and hints for removed commands.

ctrl_help_top() {
  cat <<EOF
ctrl v${CTRL_VERSION} — YAML-driven platform operations CLI

Usage: ctrl [flags] <command> [args]
       ctrl help <command>    per-command help with examples

Quick start:
  ctrl init             # generate ctrl.yaml for this project
  ctrl doctor           # tools, env vars, config
  ctrl run              # every script you can run — yours and bundled

Build pipeline:
  b  / build   <svc|all>                   Build service code locally
  i  / image   <svc|all>                   Build Docker image (no push)
  p  / push    <svc|all>                   Push image to registry
  r  / release <svc|all>                   build + image + push

Deploy:
  d  / deploy  [--release] [--sync] [target] [svc|all]
                                           Pull + start on a deployment target
  s  / sync    [target]                    Sync files to target
       diff    [target] [--json]           Declared vs running image:tag (drift)

Remote:
  ssh               [target] [-- cmd]      Interactive SSH or run a remote command
  rs / remote-status [target] [svc]        docker compose ps
  rl / remote-logs   [target] <svc>        docker compose logs  (--follow to tail)
  e  / env           [target] <svc>        Env of a running container
  cp  <src> <dst>                          Copy files locally or via named machines

Health:
  hc [svc|machine|all] [--wait N] [--count N] [--tcp] [--port N]

Scripts — one command, any host:
  run                                      List project + bundled scripts
  run <name> [args] [--on local|target|a,b|@tag|all]
                    [--check] [--show] [--own] [-n] [--yes]

  Examples: ctrl run rec --gif              ctrl run install-docker --on staging
            ctrl run sysinfo --on all       ctrl run share ./build

Config & info:
  init                                     Interactive wizard — generate ctrl.yaml
  c  / check    [--json]                   Validate ctrl.yaml
  ls / list     [services|machines]        Services or machines
  info          [machine|svc]              Project / machine / service detail
  set tag <svc> <tag> | set default <name> Edit ctrl.yaml
  h  / history  [n]                        Last n journal entries (default 20)
  doctor        [machine] [--install]      Tools, env vars, config; or a host
  mcp                                      Start stdio MCP server (JSON-RPC 2.0)
  completion    <bash|zsh>                 Print shell completion script
  upgrade                                  Upgrade ctrl to latest release

Global flags:
  -n  --dry-run        Print commands, no execution
  -v  --verbose        Extra debug output
      --json           JSON output (list, hc, info, diff, check, run, machines)
      --config <path>  Override ctrl.yaml location
      --follow         Tail logs (with rl)

[target] is a deployment or machine name. Omit to use the configured default.

EOF
}

show_command_help() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { msg_error "Usage: ctrl help <command>"; exit 1; }
  local moved
  if moved="$(ctrl_moved_command "${cmd}")"; then
    echo ""
    echo "  'ctrl ${cmd}' was removed in ctrl 0.4 — use: ${moved}"
    echo ""
    return 0
  fi

  case "${cmd}" in
    build|b)
      cat <<'EOF'

ctrl build <svc|all>   (alias: ctrl b)

  Compile service code locally using the configured build tool.
  Does not touch Docker images — use 'ctrl image' after building.

  ctrl.yaml fields read:
    services[].build.tool       maven | gradle | npm | make | shell | skip
    services[].build.dir        path to source directory (relative to ctrl.yaml)
    services[].build.args       optional extra args passed to the build tool
    services[].build.prerequisites  dirs to build first

  Examples:
    ctrl build api              # build the api service
    ctrl build all              # build every service
    ctrl b api                  # shorthand
    ctrl --dry-run b api        # print build command without running it

EOF
      ;;
    image|i)
      cat <<'EOF'

ctrl image <svc|all>   (alias: ctrl i)

  Build a Docker image locally. Does not push to the registry.
  Requires the code to be compiled first (ctrl build) unless build.tool is 'skip'.

  ctrl.yaml fields read:
    services[].image            image name (e.g. docker.io/myorg/api)
    services[].tag              image tag (default: latest)
    services[].build.dir        Docker build context

  Examples:
    ctrl image api
    ctrl image all
    ctrl i api

EOF
      ;;
    push|p)
      cat <<'EOF'

ctrl push <svc|all>   (alias: ctrl p)

  Push a previously built Docker image to the registry.

  ctrl.yaml fields read:
    services[].image   full image name including registry
    services[].tag     tag to push

  Examples:
    ctrl push api
    ctrl p all

EOF
      ;;
    release|r)
      cat <<'EOF'

ctrl release <svc|all>   (alias: ctrl r)

  Combined: build + image + push in one step.

  Examples:
    ctrl release api
    ctrl r all
    ctrl --dry-run r api   # preview all three steps

EOF
      ;;
    deploy|d)
      cat <<'EOF'

ctrl deploy [--release] [--sync] [target] [svc|all]   (alias: ctrl d)

  Pull images and (re)start services on a deployment target via SSH.

  Flags:
    --release   build + image + push each service first (was: ctrl redeploy)
    --sync      rsync the deployment's sync.paths first  (was: ctrl sync-deploy)

  ctrl.yaml fields read:
    deployments.targets[].machine        machine to deploy to
    deployments.targets[].compose_path   docker-compose.yml on the remote
    services[].deploy.compose_service    compose service name (default: service name)
    services[].deploy.depends_on         services started first

  Examples:
    ctrl deploy                    # all services, default target
    ctrl deploy prod api           # one service to prod
    ctrl deploy --release api      # release then deploy
    ctrl deploy --sync staging     # push config files, then deploy

EOF
      ;;
    ssh)
      cat <<'EOF'

ctrl ssh [target] [-- cmd]

  Open an interactive SSH session or run a single remote command.
  [target] can be a machine name or deployment name.
  Uses machines.default when omitted.

  ctrl.yaml fields read:
    machines.default              default machine
    machines.hosts[].host         SSH host (resolved from env var)
    machines.hosts[].user         SSH user (default: root)
    machines.hosts[].port         SSH port (default: 22)
    machines.hosts[].key          optional private key path
    machines.hosts[].cwd          interactive start directory
    deployments.targets[].cwd     deployment-specific start directory override

  Examples:
    ctrl ssh                      # interactive SSH to default machine
    ctrl ssh prod-vm              # SSH to named machine
    ctrl ssh prod                 # SSH to machine of prod deployment
    ctrl ssh prod -- df -h        # run remote command

EOF
      ;;
    remote-logs|rl)
      cat <<'EOF'

ctrl remote-logs [target] <svc> [lines]   (alias: ctrl rl)

  Tail docker compose logs for a service on the remote machine.

  Flags:
    --follow   continuously stream logs (ctrl rl api --follow)

  Examples:
    ctrl rl api                   # last 200 lines for api
    ctrl rl api 50                # last 50 lines
    ctrl rl api --follow          # stream live
    ctrl rl prod api --follow     # stream from prod machine

EOF
      ;;
    health-check|hc)
      cat <<'EOF'

ctrl hc [svc|machine|all ...] [--wait N] [--count N] [--tcp] [--port N]

  Health checks for services (HTTP) and machines (TCP). With no target, checks
  every service that has health config. Exit code is non-zero if any fails.

  Flags:
    --wait N          services: poll until HTTP 200, up to N seconds  (was: wait-ready)
    --count N         latency stats over N requests: min/avg/max/loss (was: ping)
    --interval S      seconds between --count samples (default 1)
    --tcp             TCP connect instead of HTTP (services use health.port)
    --port N          TCP port to check (implies --tcp)            (was: probe)

  ctrl.yaml fields read:
    services[].health.url      full URL (wins)
    services[].health.port     -> http://localhost:<port>/actuator/health
    machines.hosts[].host/port machine TCP target (SSH port by default)

  Examples:
    ctrl hc                       # every service with health config
    ctrl hc api --wait 60         # block until api is up
    ctrl hc api --count 10        # latency stats
    ctrl hc prod-vm --port 5432   # is postgres reachable on prod-vm?

EOF
      ;;
    run)
      cat <<'EOF'

ctrl run [<name> [args...]] [--on <where>] [--check] [--show] [--own] [-n] [--yes]

  One command for every script: your project's scripts and ctrl's bundled
  library (rec, share, install-docker, sysinfo, ...). With no name, lists them.

  Where a name resolves (first match wins):
    1. ctrl.yaml scripts[] entry with a path
    2. scripts/<name>.sh in the project (auto-discovered)
    3. bundled script shipped with ctrl

  Modifiers (anywhere after the name; everything else goes to the script,
  and everything after -- always does):
    --on <where>   local | <deployment|machine> | a,b | @tag | all
                   one target runs in the foreground; several run in parallel
                   with host-prefixed output and a per-host summary
    --check        pre-flight only (os, tools, env, sudo) on every host
    --show         header + source; for a project copy, the diff vs bundled
    --own          copy a bundled script into scripts/ - it becomes yours
    -n, --dry-run  print what would run; bundled scripts print exact commands
    --yes          confirm @sudo scripts without prompting
    --tag <t>      (listing only) filter by tag

  Script header (first 60 lines), overridable from ctrl.yaml scripts[]:
    # @description: one line        # @requires: ffmpeg jq
    # @group: media                 # @env: API_TOKEN
    # @os: linux darwin             # @sudo: yes
    # @remote: no                   # @dry-run: yes
    # @tags: smoke deploy           # @flags: --fps N --gif

  Env vars given to scripts: CTRL_PROJECT CTRL_PROJECT_DIR CTRL_CONFIG_FILE
  CTRL_SSH_HOST CTRL_REGISTRY CTRL_REMOTE_DIR CTRL_MACHINE_NAME CTRL_DEPLOY_NAME
  CTRL_OS CTRL_ARCH CTRL_PKG CTRL_DRY_RUN CTRL_YES CTRL_BIN F33D_URL F33D_TOKEN
  (remote runs: CTRL_REMOTE=1). Nothing is left on remote hosts.

  Examples:
    ctrl run                                  # list everything
    ctrl run rec --gif                        # record the screen -> mp4 + gif
    ctrl run install-docker --on staging      # set up docker on a VM
    ctrl run sysinfo --on all                 # every machine, in parallel
    ctrl run backup-db --check --on @db       # would it run there?
    ctrl run rec --own                        # make it yours, then edit
    ctrl run new-script cleanup               # scaffold scripts/cleanup.sh

EOF
      ;;
    cp)
      cat <<'EOF'

ctrl cp [--exclude PAT]... [--delete] [--progress|-P] <src> <dst>

  Copy files or directories with rsync between local paths and named machines
  declared in ctrl.yaml machines.hosts[].

  Endpoint format:
    ./path/to/file        local path
    machine-name:/path    remote path on a named machine

  Supported flows:
    local  -> local
    local  -> remote
    remote -> local
    remote -> remote      via a temporary local bounce directory

  Flags:
    --exclude PAT   exclude path pattern; repeatable
    --delete        delete files at destination that are not present at source
    --progress, -P  show rsync progress output

  Examples:
    ctrl cp ./build/api.jar prod:/srv/api/
    ctrl cp prod:/var/log/app.log ./tmp/app.log
    ctrl cp --exclude node_modules ./site/ prod:/srv/site/

EOF
      ;;
    diff)
      cat <<'EOF'

ctrl diff [target] [--json]

  Compare declared image:tag in ctrl.yaml against what is actually running on
  the deployment target. Shows which services are out of sync (drift).

  Examples:
    ctrl diff               # drift on default target
    ctrl diff staging       # drift on staging
    ctrl --json diff        # machine-readable output

EOF
      ;;
    list|ls)
      cat <<'EOF'

ctrl list [services|machines]   (alias: ctrl ls)

  List services (default) with kind, build tool and image:tag, or machines
  with host, user and deployment count. --json for machine-readable output.
  Scripts are listed by: ctrl run

EOF
      ;;
    set)
      cat <<'EOF'

ctrl set tag <svc> <tag>
ctrl set default <machine|deployment>

  Edit ctrl.yaml in place: a service's image tag, or machines.default /
  deployments.default.

  Examples:
    ctrl set tag api v1.4.2
    ctrl set default staging

EOF
      ;;
    doctor)
      cat <<'EOF'

ctrl doctor [machine|deployment] [--install]

  Check the tools ctrl needs (lib/tools.yaml + ctrl.yaml meta.tools[]) for this
  platform, env vars referenced in ctrl.yaml, and ctrl.yaml validity. Works
  outside a project too. With a machine or deployment, checks that host
  instead: OS, docker, compose v2, rsync, curl, sudo.

  Script-specific tools are checked by:  ctrl run <name> --check [--on ...]

  Flags:
    --install   install missing tools: the native package manager
                (brew/apt/dnf/apk) first, then a single-binary https download,
                then pip (only for tools that declare a pip package)

  Project tools use the same shape as the built-in registry:

    meta:
      tools:
        - name: scanos
          why: "Disk scanner"
          min: "1.2"
          check: scanos --version
          install:
            brew: scanos
            apt: scanos
            url: https://github.com/org/scanos/releases/latest/download/scanos-{os}-{arch}

  Examples:
    ctrl doctor
    ctrl doctor --install
    ctrl doctor prod

EOF
      ;;
    *)
      msg_warn "No per-command help for '${cmd}'. Try: ctrl help"
      exit 1
      ;;
  esac
}

# Commands removed in 0.4 → what to type instead. Prints the replacement and
# returns 0 when the name was a removed command.
ctrl_moved_command() {
  case "$1" in
    cpr|copy-run)          echo "ctrl run <name> --on <target>" ;;
    scripts|sc)            echo "ctrl run   (lists every script; --tag <t> filters)" ;;
    script)                echo "ctrl run new-script <name>" ;;
    redeploy|rd)           echo "ctrl deploy --release [target] [svc|all]" ;;
    sync-deploy|sd)        echo "ctrl deploy --sync [target] [svc|all]" ;;
    wait-ready|wr)         echo "ctrl hc <svc> --wait <seconds>" ;;
    ping)                  echo "ctrl hc <svc|machine> --count <n>" ;;
    probe)                 echo "ctrl hc <svc|machine> [--tcp] [--port N]   ·   ctrl run sniff <svc>   ·   ctrl run toolbox" ;;
    call)                  echo "ctrl run api-call <svc> <path> [--method M] [--body JSON]" ;;
    smoke-test|st)         echo "ctrl run smoke [svc|all]" ;;
    machines|m)            echo "ctrl list machines" ;;
    tag|t)                 echo "ctrl set tag <svc> <tag>" ;;
    default)               echo "ctrl set default <name>" ;;
    gitlab-project-info)   echo "ctrl run gitlab-info <project-id-or-path>" ;;
    gitlab-runner-deploy)  echo "ctrl run gitlab-runner --on <target>" ;;
    *) return 1 ;;
  esac
}

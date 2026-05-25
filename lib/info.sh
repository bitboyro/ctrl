#!/usr/bin/env bash
# info.sh — project info, machine detail, service detail

ctrl_info() {
  local target="${1:-}"

  if [[ -z "${target}" ]]; then
    _ctrl_info_project
    return
  fi

  if is_machine "${target}"; then
    _ctrl_info_machine "${target}"
  elif ctrl_service_exists "${target}"; then
    _ctrl_info_service "${target}"
  else
    fail "Unknown machine or service: '${target}'"
  fi
}

_ctrl_info_project() {
  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    local machines_count; machines_count="$(echo "${CTRL_YAML}" | yq '.machines.hosts | length // 0')"
    local services_count; services_count="$(echo "${CTRL_YAML}" | yq '.services | length // 0')"
    local deployments_count; deployments_count="$(echo "${CTRL_YAML}" | yq '.deployments.targets | length // 0')"
    local scripts_count; scripts_count="$(echo "${CTRL_YAML}" | yq '.scripts | length // 0')"
    local f33d_url; f33d_url="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"
    jq -n \
      --arg project     "${CTRL_META_PROJECT}" \
      --arg registry    "${CTRL_META_REGISTRY}" \
      --arg version     "${CTRL_VERSION}" \
      --argjson machines     "${machines_count}" \
      --argjson services     "${services_count}" \
      --argjson deployments  "${deployments_count}" \
      --argjson scripts      "${scripts_count}" \
      --arg f33d_url    "${f33d_url}" \
      '{project:$project,registry:$registry,version:$version,machines:$machines,services:$services,deployments:$deployments,scripts:$scripts,f33d_url:$f33d_url}'
    return
  fi

  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  local dep_default; dep_default="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
  local f33d_url; f33d_url="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"

  echo ""
  printf '  %s%-12s%s %s\n' "${BOLD}" "project"     "${RESET}" "${CTRL_META_PROJECT}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "version"     "${RESET}" "${CTRL_VERSION}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "registry"    "${RESET}" "${CTRL_META_REGISTRY:-—}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "config"      "${RESET}" "${CTRL_CONFIG_FILE}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "machine def" "${RESET}" "${machines_default:-—}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "deploy def"  "${RESET}" "${dep_default:-—}"
  [[ -n "${f33d_url}" && "${f33d_url}" != "null" ]] && \
    printf '  %s%-12s%s %s\n' "${BOLD}" "f33d"       "${RESET}" "${f33d_url}"

  local svc_count; svc_count="$(echo "${CTRL_YAML}" | yq '.services | length // 0')"
  local script_count; script_count="$(echo "${CTRL_YAML}" | yq '.scripts | length // 0')"
  printf '  %s%-12s%s %s\n' "${BOLD}" "services"    "${RESET}" "${svc_count}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "scripts"     "${RESET}" "${script_count}"
  echo ""

  local env_files; env_files="$(echo "${CTRL_YAML}" | yq '.meta.env_files[]? // ""' | grep -v '^$' | tr '\n' ' ')"
  [[ -n "${env_files}" ]] && printf '  %s%-12s%s %s\n' "${BOLD}" "env files" "${RESET}" "${env_files}"
  echo ""
}

_ctrl_info_machine() {
  local name="$1"
  local host; host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .host // \"\"")")"
  local user; user="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .user // \"root\"")")"
  local port; port="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .port // \"22\"")")"

  # Count deployments referencing this machine
  local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${name}\")] | length" 2>/dev/null || echo "0")"

  if [[ "${CTRL_JSON}" == "1" ]]; then
    jq -n \
      --arg name "${name}" \
      --arg host "${host}" \
      --arg user "${user}" \
      --arg port "${port}" \
      --argjson deployments "${dep_count}" \
      '{name:$name,host:$host,user:$user,port:$port,deployments:$deployments}'
    return
  fi

  echo ""
  printf '  %s%-14s%s %s\n' "${BOLD}" "machine"     "${RESET}" "${name}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "host"        "${RESET}" "${host}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "user"        "${RESET}" "${user}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "port"        "${RESET}" "${port}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "deployments" "${RESET}" "${dep_count}"
  echo ""
}

_ctrl_info_service() {
  local svc="$1"
  local kind; kind="$(ctrl_service_kind "${svc}")"
  local image; image="$(ctrl_service_field "${svc}" '.image // ""')"
  local tag; tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
  local desc; desc="$(ctrl_service_field "${svc}" '.description // ""')"
  local build_tool; build_tool="$(ctrl_service_field "${svc}" '.build.tool // ""')"
  local build_dir; build_dir="$(ctrl_service_field "${svc}" '.build.dir // ""')"
  local health_port; health_port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  local health_url; health_url="$(ctrl_service_field "${svc}" '.health.url // ""')"

  if [[ "${CTRL_JSON}" == "1" ]]; then
    jq -n \
      --arg name        "${svc}" \
      --arg kind        "${kind}" \
      --arg image       "${image}" \
      --arg tag         "${tag}" \
      --arg description "${desc}" \
      --arg build_tool  "${build_tool}" \
      --arg build_dir   "${build_dir}" \
      '{name:$name,kind:$kind,image:$image,tag:$tag,description:$description,build_tool:$build_tool,build_dir:$build_dir}'
    return
  fi

  echo ""
  printf '  %s%-14s%s %s\n' "${BOLD}" "service"    "${RESET}" "${svc}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "kind"       "${RESET}" "${kind}"
  [[ -n "${desc}" && "${desc}" != "null" ]] && \
    printf '  %s%-14s%s %s\n' "${BOLD}" "description" "${RESET}" "${desc}"
  printf '  %s%-14s%s %s:%s\n' "${BOLD}" "image"    "${RESET}" "${image}" "${tag}"
  if [[ "${kind}" != "external" ]]; then
    [[ -n "${build_tool}" && "${build_tool}" != "null" ]] && \
      printf '  %s%-14s%s %s\n' "${BOLD}" "build"   "${RESET}" "${build_tool} in ${build_dir}"
  fi
  if [[ -n "${health_url}" && "${health_url}" != "null" ]]; then
    printf '  %s%-14s%s %s\n' "${BOLD}" "health"   "${RESET}" "${health_url}"
  elif [[ -n "${health_port}" && "${health_port}" != "null" ]]; then
    printf '  %s%-14s%s port %s\n' "${BOLD}" "health" "${RESET}" "${health_port}"
  fi
  echo ""
}

ctrl_list_machines() {
  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    local -a rows=()
    while IFS= read -r mname; do
      [[ -z "${mname}" || "${mname}" == "null" ]] && continue
      local mhost; mhost="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .host // \"\"")")"
      local muser; muser="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .user // \"root\"")")"
      local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${mname}\")] | length" 2>/dev/null || echo "0")"
      rows+=("$(jq -n --arg name "${mname}" --arg host "${mhost}" --arg user "${muser}" --argjson deployments "${dep_count}" '{name:$name,host:$host,user:$user,deployments:$deployments}')")
    done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)
    printf '[%s]\n' "$(IFS=,; echo "${rows[*]+"${rows[*]}"}")"
    return
  fi

  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  printf '%s%-20s %-36s %-10s %s%s\n' "${BOLD}" "MACHINE" "HOST" "USER" "DEPLOYMENTS" "${RESET}"
  while IFS= read -r mname; do
    [[ -z "${mname}" || "${mname}" == "null" ]] && continue
    local mhost; mhost="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .host // \"\"")")"
    local muser; muser="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .user // \"root\"")")"
    local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${mname}\")] | length" 2>/dev/null || echo "0")"
    local default_marker=""
    [[ "${mname}" == "${machines_default}" ]] && default_marker=" ${DIM}(default)${RESET}"
    printf '  %-20s %-36s %-10s %s%s\n' "${mname}" "${mhost}" "${muser}" "${dep_count}" "${default_marker}"
  done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)
}

ctrl_set_default() {
  local name="$1"
  [[ -n "${name}" ]] || fail "Usage: ctrl default <name>"
  require_cmd yq

  if is_deployment_target "${name}"; then
    yq -i ".deployments.default = \"${name}\"" "${CTRL_CONFIG_FILE}"
    msg_ok "deployments.default set to '${name}'"
  elif is_machine "${name}"; then
    yq -i ".machines.default = \"${name}\"" "${CTRL_CONFIG_FILE}"
    msg_ok "machines.default set to '${name}'"
  else
    fail "Unknown machine or deployment: '${name}'"
  fi
}

ctrl_set_tag() {
  local svc="$1" tag="$2"
  [[ -n "${svc}" && -n "${tag}" ]] || fail "Usage: ctrl tag <svc> <tag>"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  require_cmd yq
  yq -i "(.services[] | select(.name == \"${svc}\") | .tag) = \"${tag}\"" "${CTRL_CONFIG_FILE}"
  msg_ok "Updated ${svc} tag to '${tag}'"
}

# ── per-command help ──────────────────────────────────────────────────────────

show_command_help() {
  local cmd="${1:-}"
  [[ -n "${cmd}" ]] || { msg_error "Usage: ctrl help <command>"; exit 1; }

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

ctrl deploy [target] [svc|all]   (alias: ctrl d)

  Pull the latest image and restart the service on the deployment target.
  Uses deployments.default when [target] is omitted.

  ctrl.yaml fields read:
    deployments.default                   default target
    deployments.targets[].name            target name
    deployments.targets[].machine         SSH machine to use
    deployments.targets[].compose_path    path to docker-compose.yml on remote
    services[].deploy.compose_service     compose service name (default: service name)
    services[].deploy.depends_on          services that must be running first

  Examples:
    ctrl deploy                 # deploy all to default target
    ctrl deploy api             # deploy api to default target
    ctrl deploy prod api        # deploy api to prod target
    ctrl d staging all          # deploy all to staging

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

ctrl health-check [svc|all]   (alias: ctrl hc)

  HTTP health check against each service's health URL.

  ctrl.yaml fields read:
    services[].health.port   port used to build http://localhost:<port>/actuator/health
    services[].health.url    explicit health URL (takes precedence over port)

  Examples:
    ctrl hc                   # check all health-configured services
    ctrl hc api               # check api only
    ctrl --json hc            # JSON output

EOF
      ;;
    ping)
      cat <<'EOF'

ctrl ping <svc|machine> [--n N] [--interval S]

  HTTP ping a service's health endpoint, or TCP ping a machine's SSH port.
  Only accepts names registered in ctrl.yaml.

  Flags:
    --n N          number of pings (default: 5)
    --interval S   seconds between pings (default: 1)

  Examples:
    ctrl ping api              # 5 HTTP pings to api's health URL
    ctrl ping api --n 10       # 10 pings
    ctrl ping prod-vm          # TCP ping to prod-vm:22

EOF
      ;;
    call)
      cat <<'EOF'

ctrl call <svc> <path> [--method M] [--body '{}'] [--header 'K: V']

  Make an authenticated REST call against a named service.
  Base URL is resolved from services[].health.port or services[].api.base_url.
  Injects Authorization: Bearer $JWT_TOKEN if JWT_TOKEN is set in env.

  Flags:
    --method GET|POST|PUT|DELETE   HTTP method (default: GET)
    --body '{...}'                 JSON request body
    --header 'K: V'                extra header; repeatable

  Examples:
    ctrl call api /actuator/info
    ctrl call api /users --method POST --body '{"name":"test"}'
    ctrl call api /health --header 'X-Custom: value'

EOF
      ;;
    probe)
      cat <<'EOF'

ctrl probe [svc|machine] [--tcp] [--http] [--port N]
ctrl probe sniff <svc> [--filter '...'] [--duration S] [--save] [--host] [--network net] [--mount src:dst]
ctrl probe shell [target] [--network net] [--mount src:dst] [--no-network]

  Unified diagnostics command. Subcommands:

  (default)  HTTP or TCP connectivity check for a named service or machine.
  sniff      Live tcpdump via ctrl-tools container on the service's Docker network.
             --host runs tcpdump directly on the host instead.
             --save writes to .local/captures/<svc>-<ts>.pcap
             With a deployment target, runs the capture on the remote machine.
  shell      Interactive shell inside the ctrl-tools container.
             ctrl-tools image: ghcr.io/bitboyro/ctrl-tools (pulled on demand)

  Shared flags (sniff + shell):
    --network <name|svc>   Docker network to join
    --mount <src:dst>      bind-mount host path; repeatable
    --no-network           isolated, no network

  Examples:
    ctrl probe api                         # HTTP probe
    ctrl probe api --tcp                   # TCP probe
    ctrl probe prod-vm --port 5432 --tcp   # TCP to postgres on prod-vm
    ctrl probe sniff api                   # live tcpdump
    ctrl probe sniff api --filter 'port 5432' --save
    ctrl probe shell --network api         # tools shell on api's network
    ctrl probe shell --mount ./logs:/data  # with mounted dir

EOF
      ;;
    doctor)
      cat <<'EOF'

ctrl doctor [--install]

  Pre-flight dependency check. Verifies all required and optional tools are
  present, checks that env vars referenced in ctrl.yaml are set, and validates
  ctrl.yaml itself.

  Flags:
    --install   auto-install any missing tools using the best available method
                (pip if python3 detected, then brew, then apt-get, then curl)

  Project tools declared in ctrl.yaml meta.tools[] are also checked:

    meta:
      tools:
        - name: scanos
          description: "Disk scanner"
          install:
            pip: scanos
            brew: scanos
            curl: https://github.com/bitboyro/scanos/releases/latest/download/scanos

  Examples:
    ctrl doctor
    ctrl doctor --install

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
    run)
      cat <<'EOF'

ctrl run <name> [args...]

  Run a named script registered in ctrl.yaml scripts[]. Scripts receive
  these env vars: CTRL_PROJECT, CTRL_SSH_HOST, CTRL_REGISTRY,
  CTRL_REMOTE_DIR, CTRL_CONFIG_FILE, CTRL_MACHINE_NAME, CTRL_DEPLOY_NAME,
  F33D_URL, F33D_TOKEN.

  Examples:
    ctrl run backup-db
    ctrl run smoke-api -- --verbose

  To create a new script: ctrl script init <name>

EOF
      ;;
    *)
      msg_warn "No per-command help for '${cmd}'. Try: ctrl help"
      exit 1
      ;;
  esac
}

#!/usr/bin/env bash
# probe.sh — ctrl ping, ctrl call, ctrl probe (sniff / shell / connectivity)

CTRL_TOOLS_IMAGE="${CTRL_TOOLS_IMAGE:-ghcr.io/bitboyro/ctrl-tools:latest}"

# ── ctrl ping ────────────────────────────────────────────────────────────────

ctrl_ping() {
  local target="" count=5 interval=1
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --n)        shift; count="$1" ;;
      --interval) shift; interval="$1" ;;
      -*)         fail "Unknown flag: $1. Usage: ctrl ping <svc|machine> [--n N] [--interval S]" ;;
      *)          [[ -z "${target}" ]] && target="$1" || fail "Unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "${target}" ]] || fail "Usage: ctrl ping <svc|machine> [--n N] [--interval S]"
  require_cmd curl

  local url=""
  if ctrl_service_exists "${target}"; then
    url="$(_svc_ping_url "${target}")"
    [[ -n "${url}" ]] || fail "Service '${target}' has no health.port or health.url defined"
    msg "Pinging ${target} → ${url}"
  elif is_machine "${target}"; then
    local host port
    host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${target}\") | .host // \"\"")")"
    port="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${target}\") | .port // \"22\"")")"
    msg "Pinging machine ${target} → ${host}:${port} (TCP)"
    _tcp_ping "${host}" "${port}" "${count}" "${interval}"
    return
  else
    fail "Unknown service or machine: '${target}'. Must be a name from ctrl.yaml."
  fi

  _http_ping "${url}" "${count}" "${interval}"
}

_svc_ping_url() {
  local svc="$1"
  local url; url="$(ctrl_service_field "${svc}" '.health.url // ""')"
  [[ -n "${url}" && "${url}" != "null" ]] && printf '%s' "${url}" && return
  local port; port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  [[ -n "${port}" && "${port}" != "null" ]] && printf 'http://localhost:%s/actuator/health' "${port}" && return
  printf ''
}

_http_ping() {
  local url="$1" count="$2" interval="$3"
  local -a times=() codes=() i
  for (( i=1; i<=count; i++ )); do
    local result code elapsed
    result="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "${url}" 2>/dev/null || echo "000 0")"
    code="${result%% *}"
    elapsed="${result##* }"
    times+=("${elapsed}")
    codes+=("${code}")
    local color="${GREEN}"
    [[ "${code}" != "200" ]] && color="${RED}"
    printf '  %s[%d]%s  %s%-3s%s  %.3fs\n' "${DIM}" "${i}" "${RESET}" "${color}" "${code}" "${RESET}" "${elapsed}"
    [[ "${i}" -lt "${count}" ]] && sleep "${interval}"
  done
  _print_ping_summary "${count}" "${times[@]+"${times[@]}"}" "${codes[@]+"${codes[@]}"}"
}

_tcp_ping() {
  local host="$1" port="$2" count="$3" interval="$4"
  require_cmd nc
  local -a times=() i
  local loss=0
  for (( i=1; i<=count; i++ )); do
    local start end elapsed ok=0
    start="$(date +%s%3N)"
    nc -z -w 3 "${host}" "${port}" 2>/dev/null && ok=1 || loss=$(( loss + 1 ))
    end="$(date +%s%3N)"
    elapsed="$(echo "scale=3; (${end} - ${start}) / 1000" | bc)"
    if [[ "${ok}" == "1" ]]; then
      printf '  %s[%d]%s  %sopen%s  %.3fs\n' "${DIM}" "${i}" "${RESET}" "${GREEN}" "${RESET}" "${elapsed}"
    else
      printf '  %s[%d]%s  %stimeout%s\n' "${DIM}" "${i}" "${RESET}" "${RED}" "${RESET}"
    fi
    times+=("${elapsed}")
    [[ "${i}" -lt "${count}" ]] && sleep "${interval}"
  done
  echo ""
  printf '  loss: %d/%d\n' "${loss}" "${count}"
}

_print_ping_summary() {
  local count="$1"; shift
  local -a times=()
  local -a codes=()
  local half=$(( count ))
  local i=0
  for arg in "$@"; do
    (( i++ ))
    if (( i <= half )); then
      times+=("${arg}")
    else
      codes+=("${arg}")
    fi
  done
  local loss=0
  for c in "${codes[@]+"${codes[@]}"}"; do
    [[ "${c}" != "200" ]] && (( loss++ )) || true
  done

  if [[ "${#times[@]}" -gt 0 ]]; then
    local min max sum t
    min="${times[0]}"; max="${times[0]}"; sum=0
    for t in "${times[@]}"; do
      sum="$(echo "${sum} + ${t}" | bc)"
      (( $(echo "${t} < ${min}" | bc -l) )) && min="${t}"
      (( $(echo "${t} > ${max}" | bc -l) )) && max="${t}"
    done
    local avg; avg="$(echo "scale=3; ${sum} / ${#times[@]}" | bc)"
    echo ""
    printf '  min=%.3fs  avg=%.3fs  max=%.3fs  loss=%d/%d\n' "${min}" "${avg}" "${max}" "${loss}" "${count}"
  fi
}

# ── ctrl call ────────────────────────────────────────────────────────────────

ctrl_call() {
  local svc="" path="" method="GET" body="" base_url=""
  local -a headers=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --method) shift; method="${1^^}" ;;
      --body)   shift; body="$1" ;;
      --header) shift; headers+=("-H" "$1") ;;
      -*)       fail "Unknown flag: $1" ;;
      *)
        if [[ -z "${svc}" ]]; then svc="$1"
        elif [[ -z "${path}" ]]; then path="$1"
        else fail "Unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done

  [[ -n "${svc}" && -n "${path}" ]] || fail "Usage: ctrl call <svc> <path> [--method GET|POST|PUT|DELETE] [--body '{}'] [--header 'K: V']"
  ctrl_service_exists "${svc}" || fail "Unknown service: '${svc}'"
  require_cmd curl

  local port url_field
  url_field="$(ctrl_service_field "${svc}" '.api.base_url // ""')"
  if [[ -n "${url_field}" && "${url_field}" != "null" ]]; then
    base_url="${url_field}"
  else
    port="$(ctrl_service_field "${svc}" '.health.port // ""')"
    [[ -n "${port}" && "${port}" != "null" ]] || \
      fail "Service '${svc}' has no health.port or api.base_url — cannot determine base URL"
    base_url="http://localhost:${port}"
  fi

  [[ "${path}" == /* ]] || path="/${path}"
  local full_url="${base_url}${path}"

  local -a curl_args=(-s -w '\n--- HTTP %{http_code} | %.3{time_total}s ---\n' --max-time 30)
  curl_args+=(-X "${method}")
  [[ -n "${body}" ]] && curl_args+=(-H 'Content-Type: application/json' -d "${body}")
  [[ -n "${JWT_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${JWT_TOKEN}")
  curl_args+=("${headers[@]+"${headers[@]}"}")
  curl_args+=("${full_url}")

  msg "${method} ${full_url}"
  run_op "curl ${method} ${full_url}" curl "${curl_args[@]}"
}

# ── ctrl probe ───────────────────────────────────────────────────────────────

ctrl_probe() {
  local subcmd="${1:-}"

  case "${subcmd}" in
    sniff)
      shift
      _probe_sniff "$@"
      ;;
    shell)
      shift
      _probe_shell "$@"
      ;;
    ""|--tcp|--http|--port|*)
      _probe_check "$@"
      ;;
  esac
}

# ── probe check (default: HTTP or TCP) ───────────────────────────────────────

_probe_check() {
  local target="" mode="http" port_override=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --tcp)  mode="tcp" ;;
      --http) mode="http" ;;
      --port) shift; port_override="$1" ;;
      -*)     fail "Unknown flag: $1. Usage: ctrl probe [svc|machine] [--tcp] [--http] [--port N]" ;;
      *)      [[ -z "${target}" ]] && target="$1" || fail "Unexpected argument: $1" ;;
    esac
    shift
  done
  [[ -n "${target}" ]] || fail "Usage: ctrl probe <svc|machine> [--tcp] [--http] [--port N]"

  if ctrl_service_exists "${target}"; then
    local port url
    if [[ "${mode}" == "tcp" || -n "${port_override}" ]]; then
      port="${port_override:-$(ctrl_service_field "${target}" '.health.port // ""')}"
      [[ -n "${port}" && "${port}" != "null" ]] || fail "Service '${target}' has no health.port"
      require_cmd nc
      msg "TCP probe: ${target} → localhost:${port}"
      if run_op "nc -z localhost ${port}" nc -z -w 3 localhost "${port}"; then
        msg_ok "port ${port} is open"
      else
        msg_error "port ${port} is closed or unreachable"; return 1
      fi
    else
      url="$(_svc_ping_url "${target}")"
      [[ -n "${url}" ]] || fail "Service '${target}' has no health.port or health.url"
      require_cmd curl
      msg "HTTP probe: ${target} → ${url}"
      local code
      code="$(run_op "curl ${url}" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || echo "000")"
      if [[ "${code}" == "200" ]]; then
        msg_ok "HTTP ${code}"
      else
        msg_error "HTTP ${code}"; return 1
      fi
    fi
  elif is_machine "${target}"; then
    local host mport
    host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${target}\") | .host // \"\"")")"
    mport="${port_override:-$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${target}\") | .port // \"22\"")")}"
    require_cmd nc
    msg "TCP probe: ${target} → ${host}:${mport}"
    if run_op "nc -z ${host} ${mport}" nc -z -w 3 "${host}" "${mport}"; then
      msg_ok "port ${mport} open on ${host}"
    else
      msg_error "port ${mport} unreachable on ${host}"; return 1
    fi
  else
    fail "Unknown service or machine: '${target}'"
  fi
}

# ── probe sniff ──────────────────────────────────────────────────────────────

_probe_sniff() {
  local target="" svc="" filter="" duration=10 save=0 host_mode=0
  local network="" mount_args=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --filter)   shift; filter="$1" ;;
      --duration) shift; duration="$1" ;;
      --save)     save=1 ;;
      --host)     host_mode=1 ;;
      --network)  shift; network="$1" ;;
      --mount)    shift; mount_args+=(-v "$1") ;;
      --no-network) network="none" ;;
      -*)         fail "Unknown flag: $1" ;;
      *)
        if ctrl_service_exists "$1" 2>/dev/null; then
          svc="$1"
        elif is_deployment_target "$1" 2>/dev/null; then
          target="$1"
        elif [[ -z "${svc}" ]]; then
          svc="$1"
        else
          fail "Unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done
  [[ -n "${svc}" ]] || fail "Usage: ctrl probe sniff <svc> [--filter 'port N'] [--duration S] [--save] [--host] [--network net] [--mount src:dst]"

  local tcpdump_cmd="tcpdump -l -n"
  [[ -n "${filter}" ]] && tcpdump_cmd="${tcpdump_cmd} ${filter}"

  if [[ "${save}" == "1" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local outdir
    outdir="$(dirname "${CTRL_CONFIG_FILE}")/.local/captures"
    mkdir -p "${outdir}"
    local pcap_file="${outdir}/${svc}-${ts}.pcap"
    tcpdump_cmd="tcpdump -n -w /capture/${svc}-${ts}.pcap"
    [[ -n "${filter}" ]] && tcpdump_cmd="${tcpdump_cmd} ${filter}"
    mount_args+=(-v "${outdir}:/capture")
    msg "Saving capture to ${pcap_file}"
  fi

  if [[ -n "${target}" ]]; then
    _probe_sniff_remote "${target}" "${svc}" "${tcpdump_cmd}" "${duration}"
    return
  fi

  if [[ "${host_mode}" == "1" ]]; then
    require_cmd tcpdump
    msg "tcpdump on host (${duration}s) — filter: ${filter:-any}"
    run_op "tcpdump -l -n ${filter}" timeout "${duration}" tcpdump -l -n ${filter:+${filter}} || true
    return
  fi

  require_cmd docker
  # Resolve Docker network from service name if not overridden
  if [[ -z "${network}" ]]; then
    local compose_svc; compose_svc="$(ctrl_service_field "${svc}" '.deploy.compose_service // ""')"
    [[ -z "${compose_svc}" || "${compose_svc}" == "null" ]] && compose_svc="${svc}"
    network="$(docker inspect "${compose_svc}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1 || true)"
    [[ -z "${network}" ]] && network="host"
  fi

  local net_arg="--network=${network}"
  [[ "${network}" == "none" ]] && net_arg="--network=none"

  msg "Sniffing ${svc} via ctrl-tools (network: ${network}, ${duration}s)"
  run_op "docker run ctrl-tools tcpdump" \
    docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
      "${net_arg}" \
      "${mount_args[@]+"${mount_args[@]}"}" \
      "${CTRL_TOOLS_IMAGE}" \
      sh -c "timeout ${duration} ${tcpdump_cmd} || true"
}

_probe_sniff_remote() {
  local target="$1" svc="$2" tcpdump_cmd="$3" duration="$4"
  resolve_deployment "${target}"
  msg "Remote sniff: ${svc} on ${CTRL_MACHINE_NAME} (${duration}s)"
  ctrl_ssh_run "timeout ${duration} ${tcpdump_cmd} || true"
}

# ── probe shell ──────────────────────────────────────────────────────────────

_probe_shell() {
  local target="" network="" mount_args=() no_network=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --network)    shift; network="$1" ;;
      --mount)      shift; mount_args+=(-v "$1") ;;
      --no-network) no_network=1 ;;
      -*)           fail "Unknown flag: $1" ;;
      *)
        if is_deployment_target "$1" 2>/dev/null || is_machine "$1" 2>/dev/null; then
          target="$1"
        else
          fail "Unknown target: '$1'. Must be a machine or deployment name."
        fi
        ;;
    esac
    shift
  done

  if [[ -n "${target}" ]]; then
    _probe_shell_remote "${target}"
    return
  fi

  require_cmd docker

  # Resolve network from service name shortcut
  if [[ -n "${network}" ]] && ctrl_service_exists "${network}" 2>/dev/null; then
    local compose_svc; compose_svc="$(ctrl_service_field "${network}" '.deploy.compose_service // ""')"
    [[ -z "${compose_svc}" || "${compose_svc}" == "null" ]] && compose_svc="${network}"
    network="$(docker inspect "${compose_svc}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | head -1 || true)"
  fi

  local net_arg=""
  if [[ "${no_network}" == "1" ]]; then
    net_arg="--network=none"
  elif [[ -n "${network}" ]]; then
    net_arg="--network=${network}"
  fi

  msg "Starting ctrl-tools shell${network:+ (network: ${network})}"
  run_op "docker run -it ctrl-tools sh" \
    docker run --rm -it \
      ${net_arg:+${net_arg}} \
      "${mount_args[@]+"${mount_args[@]}"}" \
      "${CTRL_TOOLS_IMAGE}" \
      sh
}

_probe_shell_remote() {
  local target="$1"
  if is_deployment_target "${target}"; then
    resolve_deployment "${target}"
  else
    resolve_machine "${target}"
  fi
  msg "Opening ctrl-tools shell on ${CTRL_MACHINE_NAME}"
  ctrl_ssh_run "docker run --rm -it ${CTRL_TOOLS_IMAGE} sh"
}

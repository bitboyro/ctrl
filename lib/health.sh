#!/usr/bin/env bash
# health.sh — ctrl hc: health checks for services and machines.
#
#   ctrl hc [svc|machine|all …]        one check per target (default: all with health config)
#     --wait N                          services: poll until healthy, up to N seconds
#     --count N [--interval S]          latency stats over N requests (min/avg/max/loss)
#     --tcp [--port N]                  TCP check instead of HTTP (services: health.port)
#
# Services are checked over HTTP at health.url, or http://localhost:<health.port>/actuator/health.
# With a default deployment, single checks run curl on the deployment host.
# Machines are checked over TCP at host:port (the SSH port unless --port).

# The one URL resolver for a service's health endpoint.
_svc_health_url() {
  local svc="$1"
  local url; url="$(ctrl_service_field "${svc}" '.health.url // ""')"
  [[ -n "${url}" && "${url}" != "null" ]] && printf '%s' "${url}" && return
  local port; port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  [[ -n "${port}" && "${port}" != "null" ]] && printf 'http://localhost:%s/actuator/health' "${port}" && return
  printf ''
}

_positive_int() { [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]] || fail "$1 must be a positive whole number: '$2'"; }

ctrl_hc() {
  local wait="" count="" interval=1 tcp=0 port=""
  local -a names=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --wait)     shift; wait="${1:-}";     _positive_int --wait "${wait}" ;;
      --count|-c) shift; count="${1:-}";    _positive_int --count "${count}" ;;
      --interval) shift; interval="${1:-}"; [[ "${interval}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "--interval must be a number of seconds: '${interval}'" ;;
      --tcp)      tcp=1 ;;
      --port)     shift; port="${1:-}";     _positive_int --port "${port}"; tcp=1 ;;
      -*)         fail "Unknown flag: $1. Usage: ctrl hc [svc|machine|all] [--wait N] [--count N] [--tcp] [--port N]" ;;
      *)          names+=("$1") ;;
    esac
    shift
  done

  # Remote curl through the default deployment, if one is configured
  local dep_default; dep_default="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
  if [[ -n "${dep_default}" && "${dep_default}" != "null" && -z "${count}" && "${tcp}" == "0" ]]; then
    resolve_deployment ""
  fi

  local -a targets=()
  if [[ "${#names[@]}" -eq 0 ]]; then
    while IFS= read -r s; do [[ -n "${s}" ]] && targets+=("${s}"); done < <(ctrl_health_target_names)
    [[ "${#targets[@]}" -gt 0 ]] || { msg_warn "No services with health.url or health.port"; return 0; }
  else
    local n
    for n in "${names[@]}"; do
      if [[ "${n}" == "all" || "${n}" == *,* ]] || ctrl_service_exists "${n}"; then
        local resolved; resolved="$(ctrl_resolve_health_services "${n}")"
        read -r -a svcs <<< "${resolved}"
        targets+=("${svcs[@]}")
      elif is_machine "${n}"; then
        targets+=("machine:${n}")
      else
        ctrl_valid_name "${n}"
        fail "Unknown service or machine: '${n}'. Must be a name from ctrl.yaml."
      fi
    done
  fi

  local failed=0 t
  for t in "${targets[@]}"; do
    if [[ "${t}" == machine:* ]]; then
      _hc_machine "${t#machine:}" "${port}" "${count:-1}" "${interval}" || failed=1
    elif [[ -n "${wait}" ]]; then
      wait_ready_service "${t}" "${wait}" || failed=1
    elif [[ "${tcp}" == "1" ]]; then
      _hc_service_tcp "${t}" "${port}" "${count:-1}" "${interval}" || failed=1
    elif [[ -n "${count}" ]]; then
      _hc_service_count "${t}" "${count}" "${interval}" || failed=1
    else
      health_check_service "${t}" || failed=1
    fi
  done
  return "${failed}"
}

health_check_service() {
  local svc="$1"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local kind; kind="$(ctrl_service_kind "${svc}")"
  [[ "${kind}" != "library" ]] || { msg_warn "Service '${svc}' is kind: library — health check is not applicable"; return 0; }
  local url; url="$(_svc_health_url "${svc}")"
  [[ -n "${url}" ]] || { msg_warn "No health.url or health.port for ${svc} — skipping"; return 0; }
  require_cmd curl

  local http_code
  if [[ -n "${CTRL_META_SSH_HOST:-}" ]]; then
    msg "Health check: ${svc} → ${url} (via ${CTRL_META_SSH_HOST})"
    http_code="$(ctrl_ssh_run "curl -s -o /dev/null -w '%{http_code}' --max-time 5 $(printf '%q' "${url}")" || echo "000")"
    http_code="${http_code//[[:space:]]/}"
  else
    msg "Health check: ${svc} → ${url}"
    http_code="$(run_op "curl ${url}" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || echo "000")"
  fi
  [[ "${CTRL_DRY_RUN}" == "1" ]] && return 0

  if [[ "${http_code}" == "200" ]]; then
    msg_ok "${svc} is healthy (HTTP ${http_code})"
  else
    msg_error "${svc} returned HTTP ${http_code} at ${url}"
    return 1
  fi
}

wait_ready_service() {
  local svc="$1"
  local timeout="${2:-60}"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local kind; kind="$(ctrl_service_kind "${svc}")"
  [[ "${kind}" != "library" ]] || { msg_warn "Service '${svc}' is kind: library — wait is not applicable"; return 0; }
  local url; url="$(_svc_health_url "${svc}")"
  [[ -n "${url}" ]] || { msg_warn "No health.url or health.port for ${svc} — skipping"; return 0; }
  require_cmd curl
  msg "Waiting for ${svc} to be ready (timeout: ${timeout}s)"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local http_code
    http_code="$(run_op "curl ${url}" curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}" 2>/dev/null || echo "000")"
    [[ "${CTRL_DRY_RUN}" == "1" ]] && return 0
    if [[ "${http_code}" == "200" ]]; then
      msg_ok "${svc} is ready"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  msg_error "${svc} did not become ready within ${timeout}s"
  return 1
}

# ── latency statistics ────────────────────────────────────────────────────────

_hc_service_count() {
  local svc="$1" count="$2" interval="$3"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local url; url="$(_svc_health_url "${svc}")"
  [[ -n "${url}" ]] || fail "Service '${svc}' has no health.port or health.url defined"
  require_cmd curl
  msg "Pinging ${svc} → ${url} (${count}×)"
  [[ "${CTRL_DRY_RUN}" == "1" ]] && { echo "${DIM}[DRY-RUN]${RESET} curl ${url} ×${count}"; return 0; }

  local -a times=()
  local i loss=0
  for (( i=1; i<=count; i++ )); do
    local result code elapsed
    result="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 5 "${url}" 2>/dev/null || echo "000 0")"
    code="${result%% *}"
    elapsed="${result##* }"
    local color="${GREEN}"
    if [[ "${code}" != "200" ]]; then color="${RED}"; loss=$(( loss + 1 )); else times+=("${elapsed}"); fi
    printf '  %s[%d]%s  %s%-3s%s  %.3fs\n' "${DIM}" "${i}" "${RESET}" "${color}" "${code}" "${RESET}" "${elapsed}"
    [[ "${i}" -lt "${count}" ]] && sleep "${interval}"
  done
  _hc_summary "${count}" "${loss}" "${times[@]+"${times[@]}"}"
  [[ "${loss}" -lt "${count}" ]]
}

_hc_tcp_series() {
  local host="$1" port="$2" count="$3" interval="$4"
  require_cmd nc
  [[ "${CTRL_DRY_RUN}" == "1" ]] && { echo "${DIM}[DRY-RUN]${RESET} nc -z ${host} ${port} ×${count}"; return 0; }
  local -a times=()
  local i loss=0
  for (( i=1; i<=count; i++ )); do
    local start end ms ok=0
    start="$(ctrl_now_ms)"
    nc -z -w 3 "${host}" "${port}" 2>/dev/null && ok=1 || loss=$(( loss + 1 ))
    end="$(ctrl_now_ms)"
    ms=$(( end - start ))
    local secs; secs="$(printf '%d.%03d' $(( ms / 1000 )) $(( ms % 1000 )))"
    if [[ "${ok}" == "1" ]]; then
      times+=("${secs}")
      [[ "${count}" -gt 1 ]] && printf '  %s[%d]%s  %sopen%s  %ss\n' "${DIM}" "${i}" "${RESET}" "${GREEN}" "${RESET}" "${secs}"
    else
      [[ "${count}" -gt 1 ]] && printf '  %s[%d]%s  %stimeout%s\n' "${DIM}" "${i}" "${RESET}" "${RED}" "${RESET}"
    fi
    [[ "${i}" -lt "${count}" ]] && sleep "${interval}"
  done
  if [[ "${count}" -gt 1 ]]; then
    _hc_summary "${count}" "${loss}" "${times[@]+"${times[@]}"}"
  elif [[ "${loss}" == "0" ]]; then
    msg_ok "port ${port} open on ${host} (${times[0]}s)"
  else
    msg_error "port ${port} unreachable on ${host}"
  fi
  [[ "${loss}" -lt "${count}" ]]
}

_hc_machine() {
  local name="$1" port="$2" count="$3" interval="$4"
  local host mport
  host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .host // \"\"")")"
  mport="${port:-$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .port // \"22\"")")}"
  msg "TCP check: machine ${name} → ${host}:${mport}"
  _hc_tcp_series "${host}" "${mport}" "${count}" "${interval}"
}

_hc_service_tcp() {
  local svc="$1" port="$2" count="$3" interval="$4"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  port="${port:-$(ctrl_service_field "${svc}" '.health.port // ""')}"
  [[ -n "${port}" && "${port}" != "null" ]] || fail "Service '${svc}' has no health.port (use --port N)"
  msg "TCP check: ${svc} → localhost:${port}"
  _hc_tcp_series localhost "${port}" "${count}" "${interval}"
}

# _hc_summary <count> <loss> [times…]   (times are successful samples only)
_hc_summary() {
  local count="$1" loss="$2"; shift 2
  echo ""
  if [[ "$#" -eq 0 ]]; then
    printf '  loss=%d/%d\n' "${loss}" "${count}"
    return
  fi
  printf '%s\n' "$@" | awk -v loss="${loss}" -v count="${count}" '
    NR==1 { min=$1; max=$1 } { sum+=$1; if ($1<min) min=$1; if ($1>max) max=$1 }
    END { printf "  min=%.3fs  avg=%.3fs  max=%.3fs  loss=%d/%d\n", min, sum/NR, max, loss, count }'
}

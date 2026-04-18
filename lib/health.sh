#!/usr/bin/env bash
# health.sh — health-check, wait-ready, smoke-test

_svc_health_url() {
  local svc="$1"
  local url; url="$(ctrl_service_field "${svc}" '.health.url // ""')"
  [[ -n "${url}" && "${url}" != "null" ]] && printf '%s' "${url}" && return
  # derive from meta.registry host or local defaults
  local port; port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  [[ -n "${port}" && "${port}" != "null" ]] && printf 'http://localhost:%s/actuator/health' "${port}" && return
  printf ''
}

health_check_service() {
  local svc="$1"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local url; url="$(_svc_health_url "${svc}")"
  [[ -n "${url}" ]] || { msg_warn "No health.url or health.port for ${svc} — skipping"; return 0; }
  require_cmd curl

  # If a deployment target is active, run the curl on the remote VM
  if [[ -n "${CTRL_META_SSH_HOST:-}" ]]; then
    msg "Health check: ${svc} → ${url} (via ${CTRL_META_SSH_HOST})"
    local http_code
    http_code="$(ctrl_ssh_run "curl -s -o /dev/null -w '%{http_code}' --max-time 5 '${url}'" || echo "000")"
    http_code="${http_code//[[:space:]]/}"
  else
    msg "Health check: ${svc} → ${url}"
    local http_code
    http_code="$(run_op "curl ${url}" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" || echo "000")"
  fi

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
  local url; url="$(_svc_health_url "${svc}")"
  [[ -n "${url}" ]] || { msg_warn "No health.url or health.port for ${svc} — skipping"; return 0; }
  require_cmd curl
  msg "Waiting for ${svc} to be ready (timeout: ${timeout}s)"
  local elapsed=0
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}" 2>/dev/null || echo "000")"
    if [[ "${http_code}" == "200" ]]; then
      msg_ok "${svc} is ready"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  fail "${svc} did not become ready within ${timeout}s"
}

smoke_test_services() {
  local -a svcs=("$@")
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local svc script_name script_path
  local found=0

  for svc in "${svcs[@]}"; do
    while IFS= read -r script_name; do
      [[ -z "${script_name}" || "${script_name}" == "null" ]] && continue
      found=1
      # find the script in the scripts list
      script_path="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${script_name}\") | .path // \"\"" || true)"
      [[ -n "${script_path}" && "${script_path}" != "null" ]] || fail "Smoke test script '${script_name}' not found in scripts:"
      local abs="${base}/${script_path}"
      [[ -f "${abs}" ]] || fail "Script file not found: ${abs}"
      msg "Smoke test [${svc}]: ${script_name}"
      run_op "smoke ${script_name}" bash "${abs}"
    done < <(echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | .smoke_tests[]? // \"\"")
  done

  [[ "${found}" -eq 1 ]] || msg_warn "No smoke tests defined for: ${svcs[*]}"
}

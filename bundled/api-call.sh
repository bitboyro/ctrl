#!/usr/bin/env bash
# @name: api-call
# @description: Authenticated REST call to a ctrl.yaml service (JWT_TOKEN → Bearer)
# @group: network
# @requires: curl
# @flags: <svc|url> <path> --method M --body JSON --header 'K: V'
# @remote: no
# @dry-run: yes
#
# Base URL: services[].api.base_url, else http://localhost:<health.port>.
# A full http(s):// URL works too. JWT_TOKEN, when set, is sent as a Bearer
# token through curl's stdin config, so it never appears in the process list.
#
#   ctrl run api-call api /users
#   ctrl run api-call api /users --method POST --body '{"name":"x"}'
#   ctrl run api-call https://example.com/health
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"

svc="" path="" method="GET" body=""
headers=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --method) shift; method="$(printf '%s' "${1:-GET}" | tr '[:lower:]' '[:upper:]')" ;;
    --body)   shift; body="${1:-}" ;;
    --header) shift; headers+=(-H "${1:-}") ;;
    -*)       die "Unknown flag: $1" ;;
    *)
      if [[ -z "${svc}" ]]; then svc="$1"
      elif [[ -z "${path}" ]]; then path="$1"
      else die "Unexpected argument: $1"
      fi ;;
  esac
  shift
done
[[ -n "${svc}" ]] || die "Usage: ctrl run api-call <svc|url> [path] [--method M] [--body JSON] [--header 'K: V']"
[[ "${method}" =~ ^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)$ ]] || die "Unsupported method: ${method}"

if [[ "${svc}" == http://* || "${svc}" == https://* ]]; then
  base="${svc}"
else
  [[ "${svc}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid service name: '${svc}'"
  cfg="${CTRL_CONFIG_MERGED:-${CTRL_CONFIG_FILE:-}}"
  [[ -n "${cfg}" && -f "${cfg}" ]] || die "No ctrl.yaml — pass a full URL instead of a service name"
  need_cmd yq
  exists="$(CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .name' "${cfg}")"
  [[ -n "${exists}" ]] || die "Unknown service: '${svc}'"
  base="$(CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .api.base_url // ""' "${cfg}")"
  if [[ -z "${base}" || "${base}" == "null" ]]; then
    port="$(CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .health.port // ""' "${cfg}")"
    [[ -n "${port}" && "${port}" != "null" ]] || die "Service '${svc}' has no api.base_url or health.port"
    base="http://localhost:${port}"
  fi
fi
[[ -z "${path}" || "${path}" == /* ]] || path="/${path}"
url="${base%/}${path}"

args=(-s -w '\n--- HTTP %{http_code} | %{time_total}s ---\n' --max-time 30 -X "${method}")
[[ -n "${body}" ]] && args+=(-H 'Content-Type: application/json' -d "${body}")
args+=("${headers[@]+"${headers[@]}"}")

say "${method} ${url}"
if [[ -n "${JWT_TOKEN:-}" ]]; then
  # -K - reads extra curl options from stdin: the token stays out of argv
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    printf '%s -K - # header "Authorization: Bearer <redacted>"\n' "$(printf '%q ' curl "${args[@]}" "${url}")"
  else
    printf 'header = "Authorization: Bearer %s"\n' "${JWT_TOKEN}" | curl -K - "${args[@]}" "${url}"
  fi
else
  run curl "${args[@]}" "${url}"
fi

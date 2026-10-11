#!/usr/bin/env bash
# core.sh — config loading, logging, utility helpers, machine resolver

CTRL_VERSION="$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo "unknown")"
CTRL_JOURNAL_DIR="${HOME}/.local/share/ctrl"
CTRL_JOURNAL="${CTRL_JOURNAL_DIR}/journal.jsonl"
CTRL_DRY_RUN="${CTRL_DRY_RUN:-0}"
CTRL_VERBOSE="${CTRL_VERBOSE:-0}"
CTRL_JSON="${CTRL_JSON:-0}"

# ── colour ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
  RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

# ── logging ───────────────────────────────────────────────────────────────────
msg()         { echo "${BLUE}${BOLD}==>${RESET} $*"; }
msg_ok()      { echo "${GREEN}${BOLD}ok${RESET} $*"; }
msg_warn()    { echo "${YELLOW}${BOLD}warn${RESET} $*" >&2; }
msg_error()   { echo "${RED}${BOLD}error${RESET} $*" >&2; }
msg_verbose() { [[ "${CTRL_VERBOSE}" == "1" ]] && echo "${DIM}[verbose]${RESET} $*" >&2 || true; }

fail() { msg_error "$*"; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}$(_require_hint "${cmd}")"
  done
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# "\nInstall: <platform command>" for a known tool, or empty.
_require_hint() {
  declare -f ctrl_install_hint >/dev/null 2>&1 || return 0
  local h; h="$(ctrl_install_hint "$1" 2>/dev/null || true)"
  [[ -n "${h}" ]] && printf '\nInstall: %s' "${h}" || true
}

# Names (services, machines, deployments, scripts, compose services, tags) must be
# plain tokens: they end up in yq expressions, remote shell commands and filenames.
ctrl_is_valid_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

ctrl_valid_name() {
  local value="${1:-}" what="${2:-name}"
  ctrl_is_valid_name "${value}" || fail "Invalid ${what}: '${value}' (allowed: letters, digits, '_', '.', '-')"
}

# Password-based SSH machines need sshpass.
_require_sshpass() {
  has_cmd "${CTRL_SSHPASS_CMD}" || fail "sshpass required for password-based auth.$(_require_hint sshpass)"
}

# ── dry-run executor ──────────────────────────────────────────────────────────
# Usage: run_op "description" cmd arg1 arg2 ...
run_op() {
  local desc="$1"; shift
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} ${desc}: $*"
    return 0
  fi
  msg_verbose "exec: $*"
  "$@"
}

# ── config ────────────────────────────────────────────────────────────────────
CTRL_CONFIG_FILE="${CTRL_CONFIG:-}"
CTRL_META_PROJECT=""
# shellcheck disable=SC2034
CTRL_META_REGISTRY=""
# Active SSH connection — set by resolve_machine() or resolve_deployment()
CTRL_META_SSH_HOST=""
CTRL_META_SSH_USER="root"
# shellcheck disable=SC2034
CTRL_META_SSH_PORT="22"
# shellcheck disable=SC2034
CTRL_META_SSH_KEY=""
CTRL_META_SSH_PASSWORD=""
# shellcheck disable=SC2034
CTRL_META_SSH_CWD=""
# shellcheck disable=SC2034
CTRL_META_COMPOSE_PATH="/opt/app/docker-compose.yml"
# shellcheck disable=SC2034
CTRL_META_REMOTE_DIR="${CTRL_META_REMOTE_DIR:-/opt/app}"
# shellcheck disable=SC2034
CTRL_MACHINE_NAME=""
CTRL_SSHPASS_CMD="${CTRL_SSHPASS_CMD:-sshpass}"

_find_config() {
  if [[ -n "${CTRL_CONFIG_FILE}" ]]; then
    [[ -f "${CTRL_CONFIG_FILE}" ]] || fail "Config file not found: ${CTRL_CONFIG_FILE}"
    return
  fi
  local dir="${PWD}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/ctrl.yaml" ]]; then
      CTRL_CONFIG_FILE="${dir}/ctrl.yaml"
      return
    fi
    dir="$(dirname "${dir}")"
  done
  [[ "${CTRL_CONFIG_OPTIONAL:-0}" == "1" ]] && return 1
  fail "No ctrl.yaml found. Run 'ctrl init' to create one."
}

# Directory that owns the project: where ctrl.yaml lives, or $PWD without one.
ctrl_project_dir() {
  if [[ -n "${CTRL_CONFIG_FILE}" ]]; then dirname "${CTRL_CONFIG_FILE}"; else printf '%s\n' "${PWD}"; fi
}

_require_yq() { require_cmd yq; }

# Resolve ${VAR} and $VAR references in a string using the current env, like
# envsubst did in 0.3; unset variables become empty. Pure bash — no envsubst.
_resolve_env_refs() {
  local rest="$1" out="" ref var
  while [[ "${rest}" =~ \$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*)) ]]; do
    ref="${BASH_REMATCH[0]}"; var="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
    out+="${rest%%"${ref}"*}${!var:-}"
    rest="${rest#*"${ref}"}"
  done
  printf '%s\n' "${out}${rest}"
}

# With CTRL_CONFIG_OPTIONAL=1 (run, doctor) a missing ctrl.yaml is not an
# error: CTRL_CONFIG_FILE stays empty and CTRL_YAML is an empty map.
load_config() {
  _require_yq
  if ! _find_config; then
    CTRL_CONFIG_FILE=""
    CTRL_YAML='{}'
    msg_verbose "No ctrl.yaml — running without project config"
    return 0
  fi
  msg_verbose "Loading config: ${CTRL_CONFIG_FILE}"

  local local_cfg
  local_cfg="$(dirname "${CTRL_CONFIG_FILE}")/.local/ctrl.local.yaml"
  if [[ -f "${local_cfg}" ]]; then
    msg_verbose "Merging local overrides: ${local_cfg}"
    CTRL_YAML="$(CTRL_LOCALCFG="${local_cfg}" yq '. *= load(strenv(CTRL_LOCALCFG))' "${CTRL_CONFIG_FILE}")"
  else
    CTRL_YAML="$(cat "${CTRL_CONFIG_FILE}")"
  fi

  CTRL_META_PROJECT="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.project // ""')")"
  # shellcheck disable=SC2034
  CTRL_META_REGISTRY="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.registry // ""')")"

  local env_file ctrl_base
  ctrl_base="$(dirname "${CTRL_CONFIG_FILE}")"
  local loaded_secrets=""
  local local_secrets="${ctrl_base}/.local/secrets.env"
  while IFS= read -r env_file; do
    [[ -z "${env_file}" || "${env_file}" == "null" ]] && continue
    env_file="$(_resolve_env_refs "${env_file}")"
    [[ "${env_file}" != /* ]] && env_file="${ctrl_base}/${env_file}"
    if [[ -f "${env_file}" ]]; then
      msg_verbose "Sourcing env file: ${env_file}"
      set -a
      # shellcheck disable=SC1090
      source "${env_file}"
      set +a
      [[ "${env_file}" == "${local_secrets}" ]] && loaded_secrets=1
    fi
  done < <(echo "${CTRL_YAML}" | yq '.meta.env_files[]? // ""')

  # Implicit .local/secrets.env fallback (loaded if not already loaded above)
  if [[ -z "${loaded_secrets}" && -f "${local_secrets}" ]]; then
    msg_verbose "Sourcing implicit env file: ${local_secrets}"
    set -a
    # shellcheck disable=SC1090
    source "${local_secrets}"
    set +a
  fi

  # Prefer project-local .local/journal/ when .local/ exists
  if [[ -d "${ctrl_base}/.local" ]]; then
    CTRL_JOURNAL_DIR="${ctrl_base}/.local/journal"
    CTRL_JOURNAL="${CTRL_JOURNAL_DIR}/journal.jsonl"
  fi
}

# ── machine resolver ──────────────────────────────────────────────────────────
# Sets CTRL_META_SSH_* from machines.hosts[] entry.
# Call before any SSH operation.

resolve_machine() {
  local name="${1:-}"

  # env var override takes highest priority
  [[ -n "${CTRL_MACHINE:-}" ]] && name="${CTRL_MACHINE}"

  if [[ -z "${name}" ]]; then
    name="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
    [[ -n "${name}" && "${name}" != "null" ]] || \
      fail "No machine specified and machines.default not set in ctrl.yaml"
  fi
  ctrl_valid_name "${name}" "machine name"

  local found; found="$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]] || \
    fail "Machine '${name}' not found in ctrl.yaml machines.hosts"

  CTRL_META_SSH_HOST="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .host // \"\"")")"
  CTRL_META_SSH_USER="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .user // \"root\"")")"
  CTRL_META_SSH_PORT="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .port // \"22\"")")"
  CTRL_META_SSH_KEY="$(_resolve_env_refs  "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .key // \"\"")")"
  CTRL_META_SSH_PASSWORD="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .password // \"\"")")"
  # shellcheck disable=SC2034
  CTRL_META_SSH_CWD="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .cwd // \"\"")")"
  export CTRL_META_SSH_PASSWORD
  local machine_remote_dir
  machine_remote_dir="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .remote_dir // \"\"")")"
  # shellcheck disable=SC2034
  [[ -n "${machine_remote_dir}" && "${machine_remote_dir}" != "null" ]] && CTRL_META_REMOTE_DIR="${machine_remote_dir}"
  # shellcheck disable=SC2034
  CTRL_MACHINE_NAME="${name}"

  [[ -n "${CTRL_META_SSH_HOST}" && "${CTRL_META_SSH_HOST}" != "null" ]] || \
    fail "Machine '${name}' has no host defined"

  msg_verbose "Machine: ${name} → ${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}:${CTRL_META_SSH_PORT}"
}

is_machine() {
  local candidate="${1:-}"
  ctrl_is_valid_name "${candidate}" || return 1
  local found; found="$(echo "${CTRL_YAML}" | CTRL_Q="${candidate}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]]
}

# ── service accessors ─────────────────────────────────────────────────────────

ctrl_service_names() {
  echo "${CTRL_YAML}" | yq '.services[].name'
}

ctrl_service_field() {
  local svc="$1" field="$2"
  _resolve_env_refs "$(echo "${CTRL_YAML}" | CTRL_Q="${svc}" yq ".services[] | select(.name == strenv(CTRL_Q)) | ${field}")"
}

ctrl_service_exists() {
  local svc="$1"
  local found
  found="$(echo "${CTRL_YAML}" | CTRL_Q="${svc}" yq ".services[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]]
}

ctrl_service_kind() {
  local svc="$1"
  ctrl_service_field "${svc}" '.kind // "service"'
}

ctrl_service_has_health() {
  local svc="$1"
  local url port
  url="$(ctrl_service_field "${svc}" '.health.url // ""')"
  port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  [[ -n "${url}" && "${url}" != "null" ]] || [[ -n "${port}" && "${port}" != "null" ]]
}

ctrl_health_target_names() {
  echo "${CTRL_YAML}" | yq '.services[]
    | select((.kind // "service") != "library")
    | select((.health.url // "") != "" or (.health.port // "") != "")
    | .name'
}

ctrl_resolve_services() {
  local -a out=()
  local token part normalized
  for token in "$@"; do
    IFS=',' read -r -a parts <<< "${token}"
    for part in "${parts[@]}"; do
      normalized="${part#"${part%%[![:space:]]*}"}"
      normalized="${normalized%"${normalized##*[![:space:]]}"}"
      normalized="$(tr '[:upper:]' '[:lower:]' <<< "${normalized}")"
      [[ -z "${normalized}" ]] && continue
      ctrl_valid_name "${normalized}" "service name"
      if [[ "${normalized}" == "all" ]]; then
        while IFS= read -r s; do out+=("${s}"); done < <(ctrl_service_names)
        echo "${out[@]}"; return
      fi
      ctrl_service_exists "${normalized}" || fail "Unknown service: ${normalized}"
      out+=("${normalized}")
    done
  done
  [[ "${#out[@]}" -gt 0 ]] || fail "No services resolved"
  echo "${out[@]}"
}

ctrl_resolve_health_services() {
  local -a out=()
  local token part normalized
  for token in "$@"; do
    IFS=',' read -r -a parts <<< "${token}"
    for part in "${parts[@]}"; do
      normalized="${part#"${part%%[![:space:]]*}"}"
      normalized="${normalized%"${normalized##*[![:space:]]}"}"
      normalized="$(tr '[:upper:]' '[:lower:]' <<< "${normalized}")"
      [[ -z "${normalized}" ]] && continue
      ctrl_valid_name "${normalized}" "service name"
      if [[ "${normalized}" == "all" ]]; then
        while IFS= read -r s; do out+=("${s}"); done < <(ctrl_health_target_names)
        echo "${out[@]}"; return
      fi
      ctrl_service_exists "${normalized}" || fail "Unknown service: ${normalized}"
      out+=("${normalized}")
    done
  done
  [[ "${#out[@]}" -gt 0 ]] || fail "No services resolved"
  echo "${out[@]}"
}

# ── SSH helpers ───────────────────────────────────────────────────────────────

_ssh_target() {
  [[ -n "${CTRL_META_SSH_HOST}" ]] || \
    fail "No SSH host set. Run a command that resolves a machine or deployment first."
  printf '%s@%s' "${CTRL_META_SSH_USER}" "${CTRL_META_SSH_HOST}"
}

_ssh_flags() {
  local flags=(-p "${CTRL_META_SSH_PORT}" -o StrictHostKeyChecking=accept-new)
  [[ -n "${CTRL_META_SSH_KEY}" ]] && flags+=(-i "${CTRL_META_SSH_KEY}")
  printf '%s\n' "${flags[@]}"
}

ctrl_ssh_run() {
  local command="$1"
  local target; target="$(_ssh_target)"
  local -a flags=()
  while IFS= read -r f; do flags+=("${f}"); done < <(_ssh_flags)
  if [[ -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    _require_sshpass
    msg_verbose "ssh ${target} (password auth)"
    if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
      echo "${DIM}[DRY-RUN]${RESET} ssh ${target}: ${CTRL_SSHPASS_CMD} -p <redacted> ssh ${flags[*]} ${target} ${command}"
      return 0
    fi
    "${CTRL_SSHPASS_CMD}" -p "${CTRL_META_SSH_PASSWORD}" ssh "${flags[@]}" "${target}" "${command}"
  else
    run_op "ssh ${target}" ssh "${flags[@]}" "${target}" "${command}"
  fi
}

ctrl_scp_send() {
  local src="$1" dst="$2"
  local target; target="$(_ssh_target)"
  local port="${CTRL_META_SSH_PORT}"
  local -a scp_flags=(-P "${port}" -o StrictHostKeyChecking=accept-new)
  [[ -n "${CTRL_META_SSH_KEY}" ]] && scp_flags+=(-i "${CTRL_META_SSH_KEY}")
  if [[ -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    _require_sshpass
    msg_verbose "scp ${src} → ${target}:${dst} (password auth)"
    if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
      echo "${DIM}[DRY-RUN]${RESET} scp ${src}: ${CTRL_SSHPASS_CMD} -p <redacted> scp ${scp_flags[*]} -r ${src} ${target}:${dst}"
      return 0
    fi
    "${CTRL_SSHPASS_CMD}" -p "${CTRL_META_SSH_PASSWORD}" scp "${scp_flags[@]}" -r "${src}" "${target}:${dst}"
  else
    run_op "scp ${src}" scp "${scp_flags[@]}" -r "${src}" "${target}:${dst}"
  fi
}

# ── audit journal ─────────────────────────────────────────────────────────────

journal_entry() {
  local command="$1" services="$2" exit_code="$3" duration="$4"
  mkdir -p "${CTRL_JOURNAL_DIR}"
  # jq builds the line so quotes or backslashes in any field cannot break JSONL
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg version "${CTRL_VERSION}" \
    --arg project "${CTRL_META_PROJECT}" \
    --arg command "${command}" \
    --arg services "${services}" \
    --arg host "${CTRL_META_SSH_HOST:-local}" \
    --arg operator "${USER:-unknown}" \
    --argjson duration "${duration:-0}" \
    --argjson exit_code "${exit_code:-0}" \
    '{ts:$ts,version:$version,project:$project,command:$command,services:$services,host:$host,operator:$operator,duration_s:$duration,exit_code:$exit_code}' \
    >> "${CTRL_JOURNAL}" 2>/dev/null || true
}

with_journal() {
  local cmd="$1" svcs="$2"; shift 2
  local start; start="$(date +%s)"
  local exit_code=0
  "$@" || exit_code=$?
  local end; end="$(date +%s)"
  journal_entry "${cmd}" "${svcs}" "${exit_code}" "$((end - start))"
  return "${exit_code}"
}

# ── platform ──────────────────────────────────────────────────────────────────
# In the bundled dist platform.sh is already inlined; in the repo, load it here.
if ! declare -f ctrl_platform_detect >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
fi
ctrl_platform_detect

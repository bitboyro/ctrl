#!/usr/bin/env bash
# core.sh — config loading, logging, OS detection, utility helpers

CTRL_VERSION="$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo "unknown")"
CTRL_JOURNAL_DIR="${HOME}/.local/share/ctrl"
CTRL_JOURNAL="${CTRL_JOURNAL_DIR}/journal.jsonl"
CTRL_DRY_RUN="${CTRL_DRY_RUN:-0}"
CTRL_VERBOSE="${CTRL_VERBOSE:-0}"

# ── colour ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'
  RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; RESET=''
fi

# ── logging ───────────────────────────────────────────────────────────────────
msg()       { echo "${BLUE}${BOLD}==>${RESET} $*"; }
msg_ok()    { echo "${GREEN}${BOLD}ok${RESET} $*"; }
msg_warn()  { echo "${YELLOW}${BOLD}warn${RESET} $*" >&2; }
msg_error() { echo "${RED}${BOLD}error${RESET} $*" >&2; }
msg_verbose() { [[ "${CTRL_VERBOSE}" == "1" ]] && echo "${DIM}[verbose]${RESET} $*" >&2 || true; }

fail() { msg_error "$*"; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: ${cmd}"
  done
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

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
CTRL_META_REGISTRY=""
CTRL_META_SSH_HOST=""
CTRL_META_SSH_USER="root"
CTRL_META_SSH_PORT="22"
CTRL_META_SSH_KEY=""
CTRL_META_COMPOSE_PATH="/opt/scaffold/docker-compose.yml"
CTRL_META_REMOTE_DIR="/opt/scaffold"

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
  fail "No ctrl.yaml found. Run 'ctrl init' or create one manually."
}

_require_yq() {
  require_cmd yq
}

# Resolve ${VAR} references in a string using current env
_resolve_env_refs() {
  echo "$1" | envsubst
}

load_config() {
  _find_config
  _require_yq
  msg_verbose "Loading config: ${CTRL_CONFIG_FILE}"

  # Load .local/ctrl.local.yaml overrides if present
  local local_cfg
  local_cfg="$(dirname "${CTRL_CONFIG_FILE}")/.local/ctrl.local.yaml"
  if [[ -f "${local_cfg}" ]]; then
    msg_verbose "Merging local overrides: ${local_cfg}"
    # yq merge: local overrides base (yq >=4 syntax)
    CTRL_YAML="$(yq '. *= load("'"${local_cfg}"'")' "${CTRL_CONFIG_FILE}")"
  else
    CTRL_YAML="$(cat "${CTRL_CONFIG_FILE}")"
  fi

  CTRL_META_PROJECT="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.project // ""')")"
  CTRL_META_REGISTRY="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.registry // ""')")"
  CTRL_META_SSH_HOST="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.ssh_host // ""')")"
  CTRL_META_SSH_USER="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.ssh_user // "root"')")"
  CTRL_META_SSH_PORT="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.ssh_port // "22"')")"
  CTRL_META_SSH_KEY="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.ssh_key // ""')")"
  CTRL_META_COMPOSE_PATH="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.compose_path // "/opt/scaffold/docker-compose.yml"')")"
  CTRL_META_REMOTE_DIR="$(dirname "${CTRL_META_COMPOSE_PATH}")"

  # Load env files listed in meta.env_files (optional)
  local env_file
  while IFS= read -r env_file; do
    [[ -z "${env_file}" || "${env_file}" == "null" ]] && continue
    env_file="$(_resolve_env_refs "${env_file}")"
    if [[ -f "${env_file}" ]]; then
      msg_verbose "Sourcing env file: ${env_file}"
      set -a; source "${env_file}"; set +a
    fi
  done < <(echo "${CTRL_YAML}" | yq '.meta.env_files[]? // ""')
}

# ── service accessors (read from CTRL_YAML) ───────────────────────────────────

ctrl_service_names() {
  echo "${CTRL_YAML}" | yq '.services[].name'
}

ctrl_service_field() {
  local svc="$1" field="$2"
  _resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | ${field}")"
}

ctrl_service_exists() {
  local svc="$1"
  local found
  found="$(echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]]
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

# ── SSH helpers ───────────────────────────────────────────────────────────────

_ssh_target() {
  [[ -n "${CTRL_META_SSH_HOST}" ]] || fail "meta.ssh_host is not set in ctrl.yaml"
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
  if [[ -n "${SSH_PASSWORD:-}" ]] && has_cmd sshpass; then
    run_op "ssh ${target}" sshpass -p "${SSH_PASSWORD}" ssh "${flags[@]}" "${target}" "${command}"
  else
    run_op "ssh ${target}" ssh "${flags[@]}" "${target}" "${command}"
  fi
}

ctrl_scp_send() {
  local src="$1" dst="$2"
  local target; target="$(_ssh_target)"
  local -a flags=() # scp uses -P, but we build scp_flags below directly
  # rebuild properly
  local port="${CTRL_META_SSH_PORT}"
  local -a scp_flags=(-P "${port}" -o StrictHostKeyChecking=accept-new)
  [[ -n "${CTRL_META_SSH_KEY}" ]] && scp_flags+=(-i "${CTRL_META_SSH_KEY}")
  if [[ -n "${SSH_PASSWORD:-}" ]] && has_cmd sshpass; then
    run_op "scp ${src}" sshpass -p "${SSH_PASSWORD}" scp "${scp_flags[@]}" -r "${src}" "${target}:${dst}"
  else
    run_op "scp ${src}" scp "${scp_flags[@]}" -r "${src}" "${target}:${dst}"
  fi
}

# ── audit journal ─────────────────────────────────────────────────────────────

journal_entry() {
  local command="$1" services="$2" exit_code="$3" duration="$4"
  mkdir -p "${CTRL_JOURNAL_DIR}"
  printf '{"ts":"%s","version":"%s","project":"%s","command":"%s","services":"%s","host":"%s","operator":"%s","duration_s":%s,"exit_code":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${CTRL_VERSION}" \
    "${CTRL_META_PROJECT}" \
    "${command}" \
    "${services}" \
    "${CTRL_META_SSH_HOST:-local}" \
    "${USER:-unknown}" \
    "${duration}" \
    "${exit_code}" \
    >> "${CTRL_JOURNAL}"
}

# Wrap a block and record it; usage: with_journal "cmd" "svc1 svc2" <function> [args]
with_journal() {
  local cmd="$1" svcs="$2"; shift 2
  local start; start="$(date +%s)"
  local exit_code=0
  "$@" || exit_code=$?
  local end; end="$(date +%s)"
  journal_entry "${cmd}" "${svcs}" "${exit_code}" "$((end - start))"
  return "${exit_code}"
}

#!/usr/bin/env bash
# templates.sh — embedded templates for ctrl script init

# Script template — substituted by ctrl_script_init before writing
# Placeholders: __NAME__
read -r -d '' CTRL_SCRIPT_TEMPLATE << 'TEMPLATE_EOF' || true
#!/usr/bin/env bash
# @name: __NAME__
set -euo pipefail

# Available env vars (injected by ctrl run):
#   CTRL_PROJECT      — project name from ctrl.yaml meta.project
#   CTRL_SSH_HOST     — active deployment SSH host
#   CTRL_REGISTRY     — image registry prefix
#   CTRL_REMOTE_DIR   — remote directory (dirname of compose_path)
#   CTRL_CONFIG_FILE  — path to ctrl.yaml
#   CTRL_MACHINE_NAME — active machine name
#   CTRL_DEPLOY_NAME  — active deployment name
#   F33D_URL          — notification feed URL
#   F33D_TOKEN        — notification feed token

# ── Path Detection ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CTRL_ROOT:-}" ]]; then
  _find_ctrl_root() {
    local dir="${SCRIPT_DIR}"
    while [[ "${dir}" != "/" ]]; do
      [[ -f "${dir}/ctrl.yaml" ]] && { echo "${dir}"; return 0; }
      dir="$(dirname "${dir}")"
    done
    return 1
  }
  CTRL_ROOT="$(_find_ctrl_root)" || CTRL_ROOT=""
  unset -f _find_ctrl_root
fi

# ── Deployment Context ────────────────────────────────────────────────────────
DEPLOYMENT_DIR=""
DEPLOYMENT_NAME=""
if [[ "${SCRIPT_DIR}" == */ops ]]; then
  DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
  DEPLOYMENT_NAME="$(basename "${DEPLOYMENT_DIR}")"
fi

# ── Core Library ──────────────────────────────────────────────────────────────
if [[ -n "${CTRL_ROOT}" && -f "${CTRL_ROOT}/lib/core.sh" ]]; then
  # shellcheck disable=SC1091
  source "${CTRL_ROOT}/lib/core.sh"
else
  msg()         { printf '  > %s\n' "$*" >&2; }
  msg_ok()      { printf '  + %s\n' "$*" >&2; }
  msg_warn()    { printf '  ! %s\n' "$*" >&2; }
  msg_error()   { printf '  x %s\n' "$*" >&2; }
  has_cmd()     { command -v "$1" >/dev/null 2>&1; }
  require_cmd() { has_cmd "$1" || { msg_error "'$1' required"; exit 1; }; }
  CTRL_DRY_RUN="${CTRL_DRY_RUN:-0}"
fi

# ── Dependency Checks ─────────────────────────────────────────────────────────
_check_deps() {
  # require_cmd docker
  return 0
}

# ── Help ──────────────────────────────────────────────────────────────────────
_usage() {
  cat >&2 <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [options] [args...]

Options:
  --help        Show this help
  --dry-run     Show what would be done without executing
  --output <f>  Write output to file
EOF
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
_cleanup() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 ]]; then
    msg_error "Script failed (exit ${exit_code})"
  fi
  return "${exit_code}"
}
trap _cleanup EXIT

# ── Main ──────────────────────────────────────────────────────────────────────
_main() {
  local output_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)  _usage; return 0 ;;
      --dry-run)  CTRL_DRY_RUN=1; shift ;;
      --output)   shift; output_file="${1:-}"; shift ;;
      --)         shift; break ;;
      *)          break ;;
    esac
  done

  _check_deps

  # Implementation here...
}

# ── Entry Point Guard ─────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _main "$@"
fi
TEMPLATE_EOF

ctrl_script_init() {
  local name="$1"
  [[ -n "${name}" ]] || fail "Usage: ctrl script init <name>"

  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local scripts_dir="${base}/scripts"
  local script_file="${scripts_dir}/${name}.sh"

  [[ -f "${script_file}" ]] && fail "Script already exists: ${script_file}"

  # Check not already registered
  local existing; existing="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .name" 2>/dev/null || true)"
  [[ -z "${existing}" || "${existing}" == "null" ]] || fail "Script '${name}' already registered in ctrl.yaml"

  mkdir -p "${scripts_dir}"

  # Template resolution: project override > built-in
  local template="${CTRL_SCRIPT_TEMPLATE}"
  local override="${base}/scripts/templates/ctrl-script.sh"
  if [[ -f "${override}" ]]; then
    if [[ -r "${override}" && -s "${override}" ]]; then
      template="$(cat "${override}")"
      msg_verbose "Using template override: ${override}"
    else
      msg_warn "Template override unreadable or empty, using built-in: ${override}"
    fi
  fi

  local content; content="${template//__NAME__/${name}}"
  printf '%s\n' "${content}" > "${script_file}"
  chmod +x "${script_file}"

  # Register in ctrl.yaml via yq in-place
  require_cmd yq
  yq -i ".scripts += [{\"name\": \"${name}\", \"path\": \"scripts/${name}.sh\", \"description\": \"\"}]" "${CTRL_CONFIG_FILE}"

  msg_ok "Created scripts/${name}.sh — edit it, then: ctrl run ${name}"
}

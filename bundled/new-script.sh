#!/usr/bin/env bash
# @name: new-script
# @description: Create a project script from the template (scripts/<name>.sh)
# @group: meta
# @flags: <name>
# @remote: no
# @dry-run: yes
#
# Template: scripts/templates/ctrl-script.sh in the project overrides the
# built-in one below (placeholder __NAME__). The script is registered in
# ctrl.yaml scripts[] when a ctrl.yaml exists; otherwise it is picked up from
# scripts/ automatically.
set -euo pipefail
# ctrl:lib

_new_script_main() {
common_flags "$@"
set -- "${ARGS[@]+"${ARGS[@]}"}"
name="${1:-}"
[[ -n "${name}" ]] || die "Usage: ctrl run new-script <name>"
[[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid script name: '${name}' (allowed: letters, digits, '_', '.', '-')"

project="${CTRL_PROJECT_DIR:-${PWD}}"
config="${CTRL_CONFIG_FILE:-}"
scripts_dir="${project}/scripts"
script_file="${scripts_dir}/${name}.sh"

[[ ! -f "${script_file}" ]] || die "Script already exists: ${script_file}"
if [[ -n "${config}" ]] && has yq; then
  existing="$(CTRL_Q="${name}" yq '.scripts[] | select(.name == strenv(CTRL_Q)) | .name' "${config}" 2>/dev/null || true)"
  [[ -z "${existing}" || "${existing}" == "null" ]] || die "Script '${name}' already registered in ctrl.yaml"
fi

template="$(_builtin_template)"
override="${scripts_dir}/templates/ctrl-script.sh"
if [[ -f "${override}" ]]; then
  if [[ -r "${override}" && -s "${override}" ]]; then
    template="$(cat "${override}")"
  else
    warn "Template override unreadable or empty, using built-in: ${override}"
  fi
fi

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  printf 'write %q\n' "${script_file}"
  [[ -n "${config}" ]] && printf 'register %q in %q\n' "${name}" "${config}"
  return 0
fi

mkdir -p "${scripts_dir}"
printf '%s\n' "${template//__NAME__/${name}}" > "${script_file}"
chmod +x "${script_file}"

if [[ -n "${config}" ]] && has yq; then
  CTRL_Q="${name}" yq -i '.scripts += [{"name": strenv(CTRL_Q), "path": "scripts/" + strenv(CTRL_Q) + ".sh", "description": ""}]' "${config}"
fi
ok "Created scripts/${name}.sh — edit it, then: ctrl run ${name}"
}




# ── built-in template (kept below line 60: ctrl reads headers from the first 60 lines)
_builtin_template() {
cat <<'CTRL_TEMPLATE_EOF'
#!/usr/bin/env bash
# @name: __NAME__
# @description: TODO — one line shown by `ctrl run`
# @group: project
# @requires:
# @env:
# @os:
# @remote: yes
# @sudo: no
#
# Header keys are read by ctrl: @requires / @env / @os are checked before the
# script runs (locally, and on every --on host); @sudo: yes asks for
# confirmation. A ctrl.yaml scripts[] entry with the same name overrides them.
set -euo pipefail

# Available env vars (injected by ctrl run; CTRL_REMOTE=1 when run via --on):
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
  # Declare tool/env requirements in the header (# @requires: docker jq,
  # # @env: MY_SECRET) — ctrl enforces them before this script runs, locally
  # for `ctrl run` and remotely for `ctrl run __NAME__ --on <target>`.
  #
  # For runtime-only checks not covered by requires:, call require_cmd here:
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
CTRL_TEMPLATE_EOF
}

_new_script_main "$@"

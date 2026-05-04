#!/usr/bin/env bash
# templates.sh — embedded templates for ctrl script init

# Script template — substituted by ctrl_script_init before writing
# Placeholders: __NAME__
read -r -d '' CTRL_SCRIPT_TEMPLATE << 'TEMPLATE_EOF' || true
#!/usr/bin/env bash
# @name: __NAME__
set -euo pipefail

# Available env vars (injected by ctrl run):
#   CTRL_PROJECT    — project name from ctrl.yaml meta.project
#   CTRL_SSH_HOST   — active deployment SSH host
#   CTRL_REGISTRY   — image registry prefix
#   CTRL_REMOTE_DIR — remote directory (dirname of compose_path)
#   CTRL_CONFIG_FILE — path to ctrl.yaml
#   F33D_URL        — notification feed URL
#   F33D_TOKEN      — notification feed token
#
# After the main script exits:
#   CTRL_EXIT_CODE  — exit code of this script (set by ctrl run)
#   F33D_LEVEL      — "success" or "error" (set by ctrl run)
#   F33D_MESSAGE    — "ctrl __NAME__: done/failed" (set by ctrl run)

_cleanup() {
  local exit_code=$?
  [[ "${exit_code}" -ne 0 ]] && echo "error: script failed (exit ${exit_code})" >&2
}
trap _cleanup EXIT

# ── main ──────────────────────────────────────────────────────────────────────

# your logic here
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
  local content; content="${CTRL_SCRIPT_TEMPLATE//__NAME__/${name}}"
  printf '%s\n' "${content}" > "${script_file}"
  chmod +x "${script_file}"

  # Register in ctrl.yaml via yq in-place
  require_cmd yq
  yq -i ".scripts += [{\"name\": \"${name}\", \"path\": \"scripts/${name}.sh\", \"description\": \"\"}]" "${CTRL_CONFIG_FILE}"

  msg_ok "Created scripts/${name}.sh — edit it, then: ctrl run ${name}"
}

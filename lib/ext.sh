#!/usr/bin/env bash
# ext.sh — named script runner and plugin (extension) loader

run_script() {
  local name="$1"; shift
  local extra_args=("$@")
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"

  local path desc
  path="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .path // \"\"" 2>/dev/null || true)"
  [[ -n "${path}" && "${path}" != "null" ]] || fail "Script '${name}' not found in ctrl.yaml scripts:"

  local abs="${base}/${path}"
  [[ -f "${abs}" ]] || fail "Script file not found: ${abs}"

  export CTRL_PROJECT="${CTRL_META_PROJECT}"
  export CTRL_SSH_HOST="${CTRL_META_SSH_HOST}"
  export CTRL_REGISTRY="${CTRL_META_REGISTRY}"
  export CTRL_REMOTE_DIR="${CTRL_META_REMOTE_DIR}"
  export CTRL_CONFIG_FILE

  msg "Running script: ${name}"
  run_op "script ${name}" bash "${abs}" "${extra_args[@]}"
  msg_ok "Script finished: ${name}"
}

list_scripts() {
  echo "${CTRL_YAML}" | yq '.scripts[] | "\(.name)\t\(.description // "")"' | \
    while IFS=$'\t' read -r name desc; do
      printf '  %-24s %s\n' "${name}" "${desc}"
    done
}

load_extensions() {
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local p abs
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "null" ]] && continue
    abs="${base}/${p}"
    if [[ -f "${abs}" ]]; then
      msg_verbose "Loading extension: ${abs}"
      # shellcheck disable=SC1090
      source "${abs}"
    else
      msg_warn "Extension not found, skipping: ${abs}"
    fi
  done < <(echo "${CTRL_YAML}" | yq '.extensions[]? // ""')
}

#!/usr/bin/env bash
# ext.sh — named script runner and plugin (extension) loader

run_script() {
  local name="$1"; shift
  local extra_args=("$@")
  while [[ "${#extra_args[@]}" -gt 0 && "${extra_args[0]}" == "--" ]]; do
    extra_args=("${extra_args[@]:1}")
  done
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"

  local path
  path="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .path // \"\"" 2>/dev/null || true)"
  [[ -n "${path}" && "${path}" != "null" ]] || fail "Script '${name}' not found in ctrl.yaml scripts:"

  local abs="${base}/${path}"
  [[ -f "${abs}" ]] || fail "Script file not found: ${abs}"

  export CTRL_PROJECT="${CTRL_META_PROJECT}"
  export CTRL_SSH_HOST="${CTRL_META_SSH_HOST}"
  export CTRL_REGISTRY="${CTRL_META_REGISTRY}"
  export CTRL_REMOTE_DIR="${CTRL_META_REMOTE_DIR}"
  export CTRL_CONFIG_FILE
  export CTRL_MACHINE_NAME="${CTRL_MACHINE_NAME:-}"
  export CTRL_DEPLOY_NAME="${CTRL_DEPLOY_NAME:-}"
  export F33D_URL; F33D_URL="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"
  export F33D_TOKEN; F33D_TOKEN="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.token // ""')")"

  local hook
  while IFS= read -r hook; do
    [[ -z "${hook}" || "${hook}" == "null" ]] && continue
    run_script "${hook}"
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .hooks.pre[]? // \"\"")

  msg "Running script: ${name}"
  local exit_code=0
  run_op "script ${name}" bash "${abs}" "${extra_args[@]+"${extra_args[@]}"}" || exit_code=$?

  export CTRL_EXIT_CODE="${exit_code}"
  if [[ "${exit_code}" -ne 0 ]]; then export F33D_LEVEL="error"; else export F33D_LEVEL="success"; fi
  if [[ "${exit_code}" -ne 0 ]]; then export F33D_MESSAGE="ctrl ${name}: failed"; else export F33D_MESSAGE="ctrl ${name}: done"; fi
  while IFS= read -r hook; do
    [[ -z "${hook}" || "${hook}" == "null" ]] && continue
    run_script "${hook}" || true
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .hooks.post[]? // \"\"")

  [[ "${exit_code}" -eq 0 ]] || return "${exit_code}"
  msg_ok "Script finished: ${name}"
}

list_scripts() {
  local tag="${1:-}"
  local query='.scripts[]'
  if [[ -n "${tag}" ]]; then
    query=".scripts[] | select(.tags // [] | contains([\"${tag}\"]))"
  fi
  echo "${CTRL_YAML}" | yq -r "${query} | .name + \"\t\" + (.description // \"\")" | \
    while IFS=$'\t' read -r name desc; do
      [[ -z "${name}" ]] && continue
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

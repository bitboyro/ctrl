#!/usr/bin/env bash
# ext.sh — named script runner and plugin (extension) loader

_script_preflight_check() {
  local name="$1" failed=0
  local item
  while IFS= read -r item; do
    [[ -z "${item}" || "${item}" == "null" ]] && continue
    has_cmd "${item}" || { msg_error "Script '${name}' requires tool '${item}' (not found)"; failed=1; }
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .requires.tools[]? // \"\"" 2>/dev/null || true)
  while IFS= read -r item; do
    [[ -z "${item}" || "${item}" == "null" ]] && continue
    [[ -n "${!item:-}" ]] || { msg_error "Script '${name}' requires env var '${item}' (not set)"; failed=1; }
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .requires.env[]? // \"\"" 2>/dev/null || true)
  [[ "${failed}" -eq 0 ]] || fail "Pre-flight checks failed for script '${name}'"
}

_script_preamble() {
  local name="$1"
  local -a req_tools=() req_env=()
  local item
  while IFS= read -r item; do
    [[ -z "${item}" || "${item}" == "null" ]] && continue
    req_tools+=("${item}")
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .requires.tools[]? // \"\"" 2>/dev/null || true)
  while IFS= read -r item; do
    [[ -z "${item}" || "${item}" == "null" ]] && continue
    req_env+=("${item}")
  done < <(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .requires.env[]? // \"\"" 2>/dev/null || true)
  [[ "${#req_tools[@]}" -eq 0 && "${#req_env[@]}" -eq 0 ]] && return
  printf '_ctrl_pf=0\n'
  local t
  for t in "${req_tools[@]}"; do
    printf 'command -v %q >/dev/null 2>&1 || { echo "ctrl: remote requires %q (not found)" >&2; _ctrl_pf=1; }\n' "${t}" "${t}"
  done
  local v
  for v in "${req_env[@]}"; do
    printf '[[ -n "${%s:-}" ]] || { echo "ctrl: remote requires env var %q (not set)" >&2; _ctrl_pf=1; }\n' "${v}" "${v}"
  done
  printf '[[ "${_ctrl_pf}" -eq 0 ]] || exit 1; unset _ctrl_pf\n'
}

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

  _script_preflight_check "${name}"

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

copy_run_script() {
  local name="$1"
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"

  local path
  path="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${name}\") | .path // \"\"" 2>/dev/null || true)"
  [[ -n "${path}" && "${path}" != "null" ]] || fail "Script '${name}' not found in ctrl.yaml scripts:"

  local abs="${base}/${path}"
  [[ -f "${abs}" ]] || fail "Script file not found: ${abs}"

  local target; target="$(_ssh_target)"
  local -a flags=()
  while IFS= read -r f; do flags+=("${f}"); done < <(_ssh_flags)

  # Build env preamble so the script has the same vars as local run_script
  local env_prefix
  env_prefix="CTRL_PROJECT=$(printf '%q' "${CTRL_META_PROJECT}")"
  env_prefix+=" CTRL_SSH_HOST=$(printf '%q' "${CTRL_META_SSH_HOST}")"
  env_prefix+=" CTRL_REGISTRY=$(printf '%q' "${CTRL_META_REGISTRY}")"
  env_prefix+=" CTRL_REMOTE_DIR=$(printf '%q' "${CTRL_META_REMOTE_DIR}")"

  msg "Copy-running script on remote [${CTRL_DEPLOY_NAME}]: ${name}"
  local exit_code=0
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} ssh ${target}: ${env_prefix} bash -s < ${abs}"
    local preamble; preamble="$(_script_preamble "${name}")"
    if [[ -n "${preamble}" ]]; then
      echo "${DIM}[DRY-RUN preamble]${RESET}"
      echo "${preamble}" | sed 's/^/  /'
    fi
    return 0
  fi
  if [[ -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    has_cmd "${CTRL_SSHPASS_CMD}" || fail "sshpass required for password-based auth."
    { _script_preamble "${name}"; cat "${abs}"; } | \
      "${CTRL_SSHPASS_CMD}" -p "${CTRL_META_SSH_PASSWORD}" \
        ssh "${flags[@]}" "${target}" "${env_prefix} bash -s" || exit_code=$?
  else
    { _script_preamble "${name}"; cat "${abs}"; } | \
      ssh "${flags[@]}" "${target}" "${env_prefix} bash -s" || exit_code=$?
  fi

  [[ "${exit_code}" -eq 0 ]] || return "${exit_code}"
  msg_ok "Remote script finished: ${name}"
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

#!/usr/bin/env bash
# ext.sh — extension loader (ctrl.yaml extensions[]). Scripts live in scripts.sh.

load_extensions() {
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local p abs
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "null" ]] && continue
    abs="${base}/${p}"
    if [[ -f "${abs}" ]]; then
      # Extensions are trusted code, but only from inside the project tree
      local real_dir real_base
      real_dir="$(cd "$(dirname "${abs}")" && pwd -P)"
      real_base="$(cd "${base}" && pwd -P)"
      if [[ "${real_dir}" != "${real_base}" && "${real_dir}" != "${real_base}/"* ]] || [[ "${abs}" != *.sh ]]; then
        msg_warn "Extension outside project tree or not a .sh file, skipping: ${p}"
        continue
      fi
      msg_verbose "Loading extension: ${abs}"
      # shellcheck disable=SC1090
      source "${abs}"
    else
      msg_warn "Extension not found, skipping: ${abs}"
    fi
  done < <(echo "${CTRL_YAML}" | yq '.extensions[]? // ""')
}

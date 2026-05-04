#!/usr/bin/env bash
# check.sh — ctrl.yaml structure and file reference validator

ctrl_check() {
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local -a errors=()
  local -a warnings=()

  # ── required top-level fields ─────────────────────────────────────────────
  local version; version="$(echo "${CTRL_YAML}" | yq '.ctrl.version // ""')"
  [[ -n "${version}" && "${version}" != "null" ]] || errors+=("ctrl.version is missing")

  local project; project="$(echo "${CTRL_YAML}" | yq '.meta.project // ""')"
  [[ -n "${project}" && "${project}" != "null" ]] || errors+=("meta.project is missing")

  # ── machines ──────────────────────────────────────────────────────────────
  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  if [[ -n "${machines_default}" && "${machines_default}" != "null" ]]; then
    local found_machine; found_machine="$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${machines_default}\") | .name" 2>/dev/null || true)"
    [[ -n "${found_machine}" && "${found_machine}" != "null" ]] || \
      errors+=("machines.default '${machines_default}' not found in machines.hosts")
  fi

  while IFS= read -r mname; do
    [[ -z "${mname}" || "${mname}" == "null" ]] && continue
    local mhost; mhost="$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .host // \"\"")"
    [[ -n "${mhost}" && "${mhost}" != "null" ]] || errors+=("machines.hosts[${mname}] has no host")
  done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)

  # ── deployments ───────────────────────────────────────────────────────────
  local dep_default; dep_default="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
  if [[ -n "${dep_default}" && "${dep_default}" != "null" ]]; then
    local found_dep; found_dep="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${dep_default}\") | .name" 2>/dev/null || true)"
    [[ -n "${found_dep}" && "${found_dep}" != "null" ]] || \
      errors+=("deployments.default '${dep_default}' not found in deployments.targets")
  fi

  while IFS= read -r dname; do
    [[ -z "${dname}" || "${dname}" == "null" ]] && continue
    local dmachine; dmachine="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${dname}\") | .machine // \"\"")"
    if [[ -n "${dmachine}" && "${dmachine}" != "null" ]]; then
      local found_m; found_m="$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${dmachine}\") | .name" 2>/dev/null || true)"
      [[ -n "${found_m}" && "${found_m}" != "null" ]] || \
        errors+=("deployment '${dname}' references unknown machine '${dmachine}'")
    fi
  done < <(echo "${CTRL_YAML}" | yq '.deployments.targets[].name // ""' 2>/dev/null || true)

  # ── services ──────────────────────────────────────────────────────────────
  local valid_kinds="service mcp library external"
  while IFS= read -r svc; do
    [[ -z "${svc}" || "${svc}" == "null" ]] && continue

    local kind; kind="$(ctrl_service_field "${svc}" '.kind // "service"')"
    echo " ${valid_kinds} " | grep -q " ${kind} " || errors+=("service '${svc}': unknown kind '${kind}'")

    local img; img="$(ctrl_service_field "${svc}" '.image // ""')"
    [[ -n "${img}" && "${img}" != "null" ]] || warnings+=("service '${svc}': no image defined")

    # build.dir must exist for non-external, non-library-skip services
    if [[ "${kind}" != "external" ]]; then
      local build_tool; build_tool="$(ctrl_service_field "${svc}" '.build.tool // "maven"')"
      if [[ "${build_tool}" != "skip" && "${build_tool}" != "none" ]]; then
        local build_dir; build_dir="$(ctrl_service_field "${svc}" '.build.dir // ""')"
        if [[ -n "${build_dir}" && "${build_dir}" != "null" ]]; then
          local abs_dir="${base}/${build_dir}"
          [[ -d "${abs_dir}" ]] || warnings+=("service '${svc}': build.dir not found: ${abs_dir}")
        fi
      fi
    fi

    # smoke_tests must be registered in scripts
    while IFS= read -r st; do
      [[ -z "${st}" || "${st}" == "null" ]] && continue
      local st_found; st_found="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${st}\") | .name" 2>/dev/null || true)"
      [[ -n "${st_found}" && "${st_found}" != "null" ]] || \
        errors+=("service '${svc}': smoke_test '${st}' not found in scripts:")
    done < <(echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | .smoke_tests[]? // \"\"")

  done < <(ctrl_service_names)

  # ── scripts ───────────────────────────────────────────────────────────────
  while IFS= read -r sname; do
    [[ -z "${sname}" || "${sname}" == "null" ]] && continue
    local spath; spath="$(echo "${CTRL_YAML}" | yq ".scripts[] | select(.name == \"${sname}\") | .path // \"\"" 2>/dev/null || true)"
    if [[ -n "${spath}" && "${spath}" != "null" ]]; then
      [[ -f "${base}/${spath}" ]] || warnings+=("script '${sname}': file not found: ${base}/${spath}")
    else
      errors+=("script '${sname}': missing path")
    fi
  done < <(echo "${CTRL_YAML}" | yq '.scripts[].name // ""' 2>/dev/null || true)

  # ── output ────────────────────────────────────────────────────────────────
  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    local err_json="[]" warn_json="[]"
    [[ "${#errors[@]}"   -gt 0 ]] && err_json="$(printf '%s\n' "${errors[@]}"   | jq -R . | jq -s .)"
    [[ "${#warnings[@]}" -gt 0 ]] && warn_json="$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)"
    local status="ok"
    [[ "${#errors[@]}" -gt 0 ]] && status="error"
    [[ "${#warnings[@]}" -gt 0 && "${status}" == "ok" ]] && status="warn"
    printf '{"status":"%s","errors":%s,"warnings":%s}\n' "${status}" "${err_json}" "${warn_json}"
  else
    local e w
    for e in "${errors[@]+"${errors[@]}"}"; do   msg_error "  ${e}"; done
    for w in "${warnings[@]+"${warnings[@]}"}"; do msg_warn  "  ${w}"; done
    if [[ "${#errors[@]}" -eq 0 && "${#warnings[@]}" -eq 0 ]]; then
      msg_ok "ctrl.yaml looks good"
    elif [[ "${#errors[@]}" -gt 0 ]]; then
      fail "ctrl check found ${#errors[@]} error(s)"
    fi
  fi
}

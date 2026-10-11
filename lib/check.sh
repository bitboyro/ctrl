#!/usr/bin/env bash
# check.sh — ctrl.yaml structure and file reference validator

ctrl_check() {
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local -a errors=()
  local -a warnings=()

  # ── required top-level fields ─────────────────────────────────────────────
  local version; version="$(echo "${CTRL_YAML}" | yq '.ctrl.version // ""')"
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    errors+=("ctrl.version is missing")
  elif [[ "${version}" != "${CTRL_VERSION}" ]]; then
    warnings+=("Version mismatch: ctrl.yaml declares v${version} but running v${CTRL_VERSION}")
  fi

  local project; project="$(echo "${CTRL_YAML}" | yq '.meta.project // ""')"
  [[ -n "${project}" && "${project}" != "null" ]] || errors+=("meta.project is missing")

  # ── machines ──────────────────────────────────────────────────────────────
  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  if [[ -n "${machines_default}" && "${machines_default}" != "null" ]]; then
    local found_machine; found_machine="$(echo "${CTRL_YAML}" | CTRL_Q="${machines_default}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
    [[ -n "${found_machine}" && "${found_machine}" != "null" ]] || \
      errors+=("machines.default '${machines_default}' not found in machines.hosts")
  fi

  while IFS= read -r mname; do
    [[ -z "${mname}" || "${mname}" == "null" ]] && continue
    ctrl_is_valid_name "${mname}" || { errors+=("machine name '${mname}' is not a plain token (letters, digits, _ . -)"); continue; }
    local mtag
    while IFS= read -r mtag; do
      [[ -z "${mtag}" || "${mtag}" == "null" ]] && continue
      ctrl_is_valid_name "${mtag}" || errors+=("machine '${mname}': tag '${mtag}' is not a plain token")
    done < <(echo "${CTRL_YAML}" | CTRL_Q="${mname}" yq '.machines.hosts[] | select(.name == strenv(CTRL_Q)) | .tags[]? // ""' 2>/dev/null || true)
    local mhost; mhost="$(echo "${CTRL_YAML}" | CTRL_Q="${mname}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .host // \"\"")"
    [[ -n "${mhost}" && "${mhost}" != "null" ]] || errors+=("machines.hosts[${mname}] has no host")
  done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)

  # ── deployments ───────────────────────────────────────────────────────────
  local dep_default; dep_default="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
  if [[ -n "${dep_default}" && "${dep_default}" != "null" ]]; then
    local found_dep; found_dep="$(echo "${CTRL_YAML}" | CTRL_Q="${dep_default}" yq ".deployments.targets[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
    [[ -n "${found_dep}" && "${found_dep}" != "null" ]] || \
      errors+=("deployments.default '${dep_default}' not found in deployments.targets")
  fi

  while IFS= read -r dname; do
    [[ -z "${dname}" || "${dname}" == "null" ]] && continue
    ctrl_is_valid_name "${dname}" || { errors+=("deployment name '${dname}' is not a plain token"); continue; }
    local dmachine; dmachine="$(echo "${CTRL_YAML}" | CTRL_Q="${dname}" yq ".deployments.targets[] | select(.name == strenv(CTRL_Q)) | .machine // \"\"")"
    if [[ -n "${dmachine}" && "${dmachine}" != "null" ]]; then
      local found_m; found_m="$(echo "${CTRL_YAML}" | CTRL_Q="${dmachine}" yq ".machines.hosts[] | select(.name == strenv(CTRL_Q)) | .name" 2>/dev/null || true)"
      [[ -n "${found_m}" && "${found_m}" != "null" ]] || \
        errors+=("deployment '${dname}' references unknown machine '${dmachine}'")
    fi
  done < <(echo "${CTRL_YAML}" | yq '.deployments.targets[].name // ""' 2>/dev/null || true)

  # ── services ──────────────────────────────────────────────────────────────
  local valid_kinds="service mcp library external"
  while IFS= read -r svc; do
    [[ -z "${svc}" || "${svc}" == "null" ]] && continue
    ctrl_is_valid_name "${svc}" || { errors+=("service name '${svc}' is not a plain token"); continue; }

    # compose names end up in remote shell commands
    local cs; cs="$(ctrl_service_field "${svc}" '.deploy.compose_service // ""')"
    [[ -z "${cs}" || "${cs}" == "null" ]] || ctrl_is_valid_name "${cs}" || \
      errors+=("service '${svc}': deploy.compose_service '${cs}' is not a plain token")
    local dep
    while IFS= read -r dep; do
      [[ -z "${dep}" || "${dep}" == "null" ]] && continue
      ctrl_is_valid_name "${dep}" || errors+=("service '${svc}': deploy.depends_on entry '${dep}' is not a plain token")
    done < <(echo "${CTRL_YAML}" | CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .deploy.depends_on[]? // ""' 2>/dev/null || true)

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

    # smoke_tests must resolve to a runnable script (yaml, scripts/, or bundled)
    while IFS= read -r st; do
      [[ -z "${st}" || "${st}" == "null" ]] && continue
      _check_script_resolves "${st}" || \
        errors+=("service '${svc}': smoke_test '${st}' is not a known script (ctrl.yaml scripts:, scripts/${st}.sh, or bundled)")
    done < <(echo "${CTRL_YAML}" | CTRL_Q="${svc}" yq ".services[] | select(.name == strenv(CTRL_Q)) | .smoke_tests[]? // \"\"")

  done < <(ctrl_service_names)

  # ── scripts ───────────────────────────────────────────────────────────────
  while IFS= read -r sname; do
    [[ -z "${sname}" || "${sname}" == "null" ]] && continue
    ctrl_is_valid_name "${sname}" || { errors+=("script name '${sname}' is not a plain token"); continue; }
    local spath; spath="$(echo "${CTRL_YAML}" | CTRL_Q="${sname}" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | .path // \"\"" 2>/dev/null || true)"
    if [[ -n "${spath}" && "${spath}" != "null" ]]; then
      [[ -f "${base}/${spath}" ]] || warnings+=("script '${sname}': file not found: ${base}/${spath}")
    elif [[ ! -f "${base}/scripts/${sname}.sh" ]] && ! ctrl_bundled_exists "${sname}"; then
      errors+=("script '${sname}': no path, no scripts/${sname}.sh and no bundled script of that name")
    fi

    # requires.tools — entries must not contain whitespace
    local rtool
    while IFS= read -r rtool; do
      [[ -z "${rtool}" || "${rtool}" == "null" ]] && continue
      [[ "${rtool}" =~ [[:space:]] ]] && \
        warnings+=("script '${sname}': requires.tools entry contains whitespace: '${rtool}'")
    done < <(echo "${CTRL_YAML}" | CTRL_Q="${sname}" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | .requires.tools[]? // \"\"" 2>/dev/null || true)

    # requires.env — entries must be valid shell variable names
    local renv
    while IFS= read -r renv; do
      [[ -z "${renv}" || "${renv}" == "null" ]] && continue
      [[ "${renv}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
        errors+=("script '${sname}': requires.env entry is not a valid variable name: '${renv}'")
    done < <(echo "${CTRL_YAML}" | CTRL_Q="${sname}" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | .requires.env[]? // \"\"" 2>/dev/null || true)

  done < <(echo "${CTRL_YAML}" | yq '.scripts[].name // ""' 2>/dev/null || true)

  # ── script headers (project scripts/*.sh) ─────────────────────────────────
  local sf
  for sf in "${base}"/scripts/*.sh; do
    [[ -f "${sf}" ]] || continue
    local sn; sn="$(basename "${sf}" .sh)"
    ctrl_is_valid_name "${sn}" || { warnings+=("scripts/${sn}.sh: name is not a plain token — ctrl run cannot address it"); continue; }
    local hv item
    hv="$(_script_header "${sf}" os)"
    for item in ${hv}; do
      [[ "${item}" == "linux" || "${item}" == "darwin" ]] || errors+=("scripts/${sn}.sh: @os '${item}' (use linux and/or darwin)")
    done
    for item in remote sudo dry-run; do
      hv="$(_script_header "${sf}" "${item}")"
      [[ -z "${hv}" || "${hv}" =~ ^(yes|no|true|false)$ ]] || errors+=("scripts/${sn}.sh: @${item} must be yes or no, got '${hv}'")
    done
    hv="$(_script_header "${sf}" env) $(_script_header "${sf}" env-optional)"
    for item in ${hv}; do
      [[ "${item}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || errors+=("scripts/${sn}.sh: @env '${item}' is not a variable name")
    done
    hv="$(_script_header "${sf}" requires)"
    for item in ${hv}; do
      ctrl_is_valid_name "${item}" || errors+=("scripts/${sn}.sh: @requires '${item}' is not a command name")
    done
  done

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

# 0 when a script name resolves: ctrl.yaml entry, scripts/<name>.sh, or bundled.
_check_script_resolves() {
  local n="$1" base; base="$(ctrl_project_dir)"
  ctrl_is_valid_name "${n}" || return 1
  [[ -n "$(echo "${CTRL_YAML}" | CTRL_Q="${n}" yq '.scripts[] | select(.name == strenv(CTRL_Q)) | .name' 2>/dev/null)" ]] && return 0
  [[ -f "${base}/scripts/${n}.sh" ]] && return 0
  ctrl_bundled_exists "${n}"
}

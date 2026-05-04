#!/usr/bin/env bash
# info.sh — project info, machine detail, service detail

ctrl_info() {
  local target="${1:-}"

  if [[ -z "${target}" ]]; then
    _ctrl_info_project
    return
  fi

  if is_machine "${target}"; then
    _ctrl_info_machine "${target}"
  elif ctrl_service_exists "${target}"; then
    _ctrl_info_service "${target}"
  else
    fail "Unknown machine or service: '${target}'"
  fi
}

_ctrl_info_project() {
  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    local machines_count; machines_count="$(echo "${CTRL_YAML}" | yq '.machines.hosts | length // 0')"
    local services_count; services_count="$(echo "${CTRL_YAML}" | yq '.services | length // 0')"
    local deployments_count; deployments_count="$(echo "${CTRL_YAML}" | yq '.deployments.targets | length // 0')"
    local scripts_count; scripts_count="$(echo "${CTRL_YAML}" | yq '.scripts | length // 0')"
    local f33d_url; f33d_url="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"
    printf '{"project":"%s","registry":"%s","version":"%s","machines":%s,"services":%s,"deployments":%s,"scripts":%s,"f33d_url":"%s"}\n' \
      "${CTRL_META_PROJECT}" "${CTRL_META_REGISTRY}" "${CTRL_VERSION}" \
      "${machines_count}" "${services_count}" "${deployments_count}" "${scripts_count}" "${f33d_url}"
    return
  fi

  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  local dep_default; dep_default="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
  local f33d_url; f33d_url="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"

  echo ""
  printf '  %s%-12s%s %s\n' "${BOLD}" "project"     "${RESET}" "${CTRL_META_PROJECT}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "version"     "${RESET}" "${CTRL_VERSION}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "registry"    "${RESET}" "${CTRL_META_REGISTRY:-—}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "config"      "${RESET}" "${CTRL_CONFIG_FILE}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "machine def" "${RESET}" "${machines_default:-—}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "deploy def"  "${RESET}" "${dep_default:-—}"
  [[ -n "${f33d_url}" && "${f33d_url}" != "null" ]] && \
    printf '  %s%-12s%s %s\n' "${BOLD}" "f33d"       "${RESET}" "${f33d_url}"

  local svc_count; svc_count="$(echo "${CTRL_YAML}" | yq '.services | length // 0')"
  local script_count; script_count="$(echo "${CTRL_YAML}" | yq '.scripts | length // 0')"
  printf '  %s%-12s%s %s\n' "${BOLD}" "services"    "${RESET}" "${svc_count}"
  printf '  %s%-12s%s %s\n' "${BOLD}" "scripts"     "${RESET}" "${script_count}"
  echo ""

  local env_files; env_files="$(echo "${CTRL_YAML}" | yq '.meta.env_files[]? // ""' | grep -v '^$' | tr '\n' ' ')"
  [[ -n "${env_files}" ]] && printf '  %s%-12s%s %s\n' "${BOLD}" "env files" "${RESET}" "${env_files}"
  echo ""
}

_ctrl_info_machine() {
  local name="$1"
  local host; host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .host // \"\"")")"
  local user; user="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .user // \"root\"")")"
  local port; port="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${name}\") | .port // \"22\"")")"

  # Count deployments referencing this machine
  local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${name}\")] | length" 2>/dev/null || echo "0")"

  if [[ "${CTRL_JSON}" == "1" ]]; then
    printf '{"name":"%s","host":"%s","user":"%s","port":"%s","deployments":%s}\n' \
      "${name}" "${host}" "${user}" "${port}" "${dep_count}"
    return
  fi

  echo ""
  printf '  %s%-14s%s %s\n' "${BOLD}" "machine"     "${RESET}" "${name}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "host"        "${RESET}" "${host}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "user"        "${RESET}" "${user}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "port"        "${RESET}" "${port}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "deployments" "${RESET}" "${dep_count}"
  echo ""
}

_ctrl_info_service() {
  local svc="$1"
  local kind; kind="$(ctrl_service_kind "${svc}")"
  local image; image="$(ctrl_service_field "${svc}" '.image // ""')"
  local tag; tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
  local desc; desc="$(ctrl_service_field "${svc}" '.description // ""')"
  local build_tool; build_tool="$(ctrl_service_field "${svc}" '.build.tool // ""')"
  local build_dir; build_dir="$(ctrl_service_field "${svc}" '.build.dir // ""')"
  local health_port; health_port="$(ctrl_service_field "${svc}" '.health.port // ""')"
  local health_url; health_url="$(ctrl_service_field "${svc}" '.health.url // ""')"

  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    printf '{"name":"%s","kind":"%s","image":"%s","tag":"%s","description":"%s","build_tool":"%s","build_dir":"%s"}\n' \
      "${svc}" "${kind}" "${image}" "${tag}" "${desc}" "${build_tool}" "${build_dir}" | jq .
    return
  fi

  echo ""
  printf '  %s%-14s%s %s\n' "${BOLD}" "service"    "${RESET}" "${svc}"
  printf '  %s%-14s%s %s\n' "${BOLD}" "kind"       "${RESET}" "${kind}"
  [[ -n "${desc}" && "${desc}" != "null" ]] && \
    printf '  %s%-14s%s %s\n' "${BOLD}" "description" "${RESET}" "${desc}"
  printf '  %s%-14s%s %s:%s\n' "${BOLD}" "image"    "${RESET}" "${image}" "${tag}"
  if [[ "${kind}" != "external" ]]; then
    [[ -n "${build_tool}" && "${build_tool}" != "null" ]] && \
      printf '  %s%-14s%s %s\n' "${BOLD}" "build"   "${RESET}" "${build_tool} in ${build_dir}"
  fi
  if [[ -n "${health_url}" && "${health_url}" != "null" ]]; then
    printf '  %s%-14s%s %s\n' "${BOLD}" "health"   "${RESET}" "${health_url}"
  elif [[ -n "${health_port}" && "${health_port}" != "null" ]]; then
    printf '  %s%-14s%s port %s\n' "${BOLD}" "health" "${RESET}" "${health_port}"
  fi
  echo ""
}

ctrl_list_machines() {
  if [[ "${CTRL_JSON}" == "1" ]]; then
    require_cmd jq
    local -a rows=()
    while IFS= read -r mname; do
      [[ -z "${mname}" || "${mname}" == "null" ]] && continue
      local mhost; mhost="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .host // \"\"")")"
      local muser; muser="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .user // \"root\"")")"
      local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${mname}\")] | length" 2>/dev/null || echo "0")"
      rows+=("{\"name\":\"${mname}\",\"host\":\"${mhost}\",\"user\":\"${muser}\",\"deployments\":${dep_count}}")
    done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)
    printf '[%s]\n' "$(IFS=,; echo "${rows[*]+"${rows[*]}"}")"
    return
  fi

  local machines_default; machines_default="$(echo "${CTRL_YAML}" | yq '.machines.default // ""')"
  printf '%s%-20s %-36s %-10s %s%s\n' "${BOLD}" "MACHINE" "HOST" "USER" "DEPLOYMENTS" "${RESET}"
  while IFS= read -r mname; do
    [[ -z "${mname}" || "${mname}" == "null" ]] && continue
    local mhost; mhost="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .host // \"\"")")"
    local muser; muser="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".machines.hosts[] | select(.name == \"${mname}\") | .user // \"root\"")")"
    local dep_count; dep_count="$(echo "${CTRL_YAML}" | yq "[.deployments.targets[] | select(.machine == \"${mname}\")] | length" 2>/dev/null || echo "0")"
    local default_marker=""
    [[ "${mname}" == "${machines_default}" ]] && default_marker=" ${DIM}(default)${RESET}"
    printf '  %-20s %-36s %-10s %s%s\n' "${mname}" "${mhost}" "${muser}" "${dep_count}" "${default_marker}"
  done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null || true)
}

ctrl_set_default() {
  local name="$1"
  [[ -n "${name}" ]] || fail "Usage: ctrl default <name>"
  require_cmd yq

  if is_deployment_target "${name}"; then
    yq -i ".deployments.default = \"${name}\"" "${CTRL_CONFIG_FILE}"
    msg_ok "deployments.default set to '${name}'"
  elif is_machine "${name}"; then
    yq -i ".machines.default = \"${name}\"" "${CTRL_CONFIG_FILE}"
    msg_ok "machines.default set to '${name}'"
  else
    fail "Unknown machine or deployment: '${name}'"
  fi
}

ctrl_set_tag() {
  local svc="$1" tag="$2"
  [[ -n "${svc}" && -n "${tag}" ]] || fail "Usage: ctrl tag <svc> <tag>"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  require_cmd yq
  yq -i "(.services[] | select(.name == \"${svc}\") | .tag) = \"${tag}\"" "${CTRL_CONFIG_FILE}"
  msg_ok "Updated ${svc} tag to '${tag}'"
}

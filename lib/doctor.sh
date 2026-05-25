#!/usr/bin/env bash
# doctor.sh — pre-flight dependency check with install hints

ctrl_doctor() {
  local auto_install=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --install) auto_install=1 ;;
      *) fail "Unknown flag: $1. Usage: ctrl doctor [--install]" ;;
    esac
    shift
  done

  local all_ok=1

  echo ""
  printf '  %s%-16s %-8s %s%s\n' "${BOLD}" "TOOL" "STATUS" "NOTE" "${RESET}"
  echo "  ──────────────────────────────────────────────────────────"

  # Required tools
  _doctor_check_tool "yq"     required "YAML parsing"                   "brew install yq"           ""                      "pip install yq"           "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"       all_ok "${auto_install}"
  _doctor_check_tool "jq"     required "JSON processing"                "brew install jq"           "apt-get install jq"    ""                         "https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64"           all_ok "${auto_install}"
  _doctor_check_tool "curl"   required "health checks, GitLab, f33d"    "brew install curl"         "apt-get install curl"  ""                         ""                                                                                all_ok "${auto_install}"
  _doctor_check_tool "ssh"    required "remote access"                  "brew install openssh"      "apt-get install openssh-client" ""               ""                                                                                all_ok "${auto_install}"
  _doctor_check_tool "docker" required "build/push/deploy/probe"        "brew install --cask docker" "apt-get install docker.io" ""                  ""                                                                                all_ok "${auto_install}"
  _doctor_check_tool "rsync"  required "sync commands"                  "brew install rsync"        "apt-get install rsync" ""                         ""                                                                                all_ok "${auto_install}"

  echo "  ──────────────────────────────────────────────────────────"

  # Optional tools
  _doctor_check_tool "nc"      optional "ctrl probe --tcp"              "brew install netcat"       "apt-get install netcat" ""                        ""                                                                               all_ok "${auto_install}"
  _doctor_check_tool "tcpdump" optional "ctrl probe sniff --host"       "brew install tcpdump"      "apt-get install tcpdump" ""                       ""                                                                               all_ok "${auto_install}"
  _doctor_check_tool "sshpass" optional "password-based SSH machines"   "brew install sshpass"      "apt-get install sshpass" ""                       ""                                                                               all_ok "${auto_install}"

  echo "  ──────────────────────────────────────────────────────────"

  # Optional project tools (from meta.tools in ctrl.yaml)
  _doctor_check_project_tools all_ok "${auto_install}" || true

  echo ""

  # Env var check
  _doctor_check_env_vars all_ok || true

  # ctrl.yaml validity
  echo ""
  printf '  %s%-16s%s ' "${BOLD}" "ctrl.yaml" "${RESET}"
  if ctrl_check >/dev/null 2>&1; then
    printf '%s%-8s%s\n' "${GREEN}" "ok" "${RESET}"
  else
    printf '%s%-8s%s %s\n' "${RED}" "invalid" "${RESET}" "run 'ctrl check' for details"
    all_ok=0
  fi

  echo ""
  if [[ "${all_ok}" == "1" ]]; then
    msg_ok "All checks passed"
  else
    msg_warn "Some checks failed. Run 'ctrl doctor --install' to auto-install missing tools."
  fi
}

_doctor_check_tool() {
  local name="$1" kind="$2" note="$3"
  local brew_hint="$4" apt_hint="$5" pip_hint="$6" curl_hint="$7"
  local _ok_ref_name="$8"
  local auto_install="$9"

  printf '  %-16s ' "${name}"

  if has_cmd "${name}"; then
    printf '%s%-8s%s %s\n' "${GREEN}" "ok" "${RESET}" "${note}"
    return
  fi

  if [[ "${kind}" == "required" ]]; then
    printf '%s%-8s%s' "${RED}" "missing" "${RESET}"
    eval "${_ok_ref_name}=0"
  else
    printf '%s%-8s%s' "${YELLOW}" "missing" "${RESET}"
  fi

  local install_cmd
  install_cmd="$(_doctor_best_install "${brew_hint}" "${apt_hint}" "${pip_hint}" "${curl_hint}")"
  printf '  install: %s\n' "${install_cmd}"

  if [[ "${auto_install}" == "1" && -n "${install_cmd}" ]]; then
    msg "Installing ${name}: ${install_cmd}"
    eval "${install_cmd}" && msg_ok "${name} installed" || msg_warn "Failed to install ${name}"
  fi
}

_doctor_best_install() {
  local brew_hint="$1" apt_hint="$2" pip_hint="$3" curl_hint="$4"
  if [[ -n "${pip_hint}" ]] && has_cmd python3; then
    echo "pip install ${pip_hint}"
  elif [[ -n "${brew_hint}" ]] && has_cmd brew; then
    echo "${brew_hint}"
  elif [[ -n "${apt_hint}" ]] && has_cmd apt-get; then
    echo "sudo ${apt_hint}"
  elif [[ -n "${curl_hint}" ]]; then
    local bin; bin="$(basename "${curl_hint}")"
    echo "curl -fsSL ${curl_hint} -o ~/.local/bin/${bin} && chmod +x ~/.local/bin/${bin}"
  fi
}

_doctor_check_project_tools() {
  local _ok_ref2_name="$1"
  local auto_install="$2"

  local tools_count; tools_count="$(echo "${CTRL_YAML}" | yq '.meta.tools | length // 0' 2>/dev/null || echo "0")"
  [[ "${tools_count}" -gt 0 ]] || return

  echo "  Project tools (meta.tools):"
  local i
  for (( i=0; i<tools_count; i++ )); do
    local tname tdesc pip_h brew_h curl_h
    tname="$(echo "${CTRL_YAML}" | yq ".meta.tools[${i}].name // \"\"")"
    tdesc="$(echo "${CTRL_YAML}" | yq ".meta.tools[${i}].description // \"\"")"
    pip_h="$(echo "${CTRL_YAML}" | yq ".meta.tools[${i}].install.pip // \"\"")"
    brew_h="$(echo "${CTRL_YAML}" | yq ".meta.tools[${i}].install.brew // \"\"")"
    curl_h="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".meta.tools[${i}].install.curl // \"\"")")"
    [[ -z "${tname}" || "${tname}" == "null" ]] && continue

    local brew_cmd=""
    [[ -n "${brew_h}" && "${brew_h}" != "null" ]] && brew_cmd="brew install ${brew_h}"
    local pip_cmd=""
    [[ -n "${pip_h}" && "${pip_h}" != "null" ]] && pip_cmd="${pip_h}"
    local curl_cmd=""
    [[ -n "${curl_h}" && "${curl_h}" != "null" ]] && curl_cmd="${curl_h}"

    _doctor_check_tool "${tname}" optional "${tdesc}" "${brew_cmd}" "" "${pip_cmd}" "${curl_cmd}" "${_ok_ref2_name}" "${auto_install}"
  done
}

_doctor_check_env_vars() {
  local _ok_ref3_name="$1"

  # Extract all ${VAR} references from ctrl.yaml
  local -a vars=()
  while IFS= read -r var; do
    [[ -n "${var}" ]] && vars+=("${var}")
  done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "${CTRL_CONFIG_FILE}" 2>/dev/null | sed 's/[${}]//g' | sort -u || true)

  [[ "${#vars[@]}" -eq 0 ]] && return

  echo "  Env vars referenced in ctrl.yaml:"
  printf '  %s%-24s %-8s%s\n' "${BOLD}" "VAR" "STATUS" "${RESET}"
  local var
  for var in "${vars[@]}"; do
    printf '  %-24s ' "${var}"
    if [[ -n "${!var:-}" ]]; then
      printf '%s%s%s\n' "${GREEN}" "set" "${RESET}"
    else
      printf '%s%s%s\n' "${YELLOW}" "unset" "${RESET}"
      eval "${_ok_ref3_name}=0"
    fi
  done
}

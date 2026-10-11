#!/usr/bin/env bash
# doctor.sh — pre-flight check of ctrl's own tools (lib/tools.yaml + meta.tools),
# env vars referenced by ctrl.yaml, and ctrl.yaml validity. Optionally checks a
# remote machine. Script-specific tools are checked by `ctrl run <name> --check`.

ctrl_doctor() {
  local auto_install=0 target=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --install) auto_install=1 ;;
      -*) fail "Unknown flag: $1. Usage: ctrl doctor [machine|deployment] [--install]" ;;
      *)  [[ -z "${target}" ]] && target="$1" || fail "Unexpected argument: $1" ;;
    esac
    shift
  done

  if [[ -n "${target}" ]]; then
    _doctor_remote "${target}"
    return
  fi

  local all_ok=1
  echo ""
  printf '  %s%-16s%s %s/%s (package manager: %s)\n' "${BOLD}" "platform" "${RESET}" "${CTRL_OS}" "${CTRL_ARCH}" "${CTRL_PKG}"
  echo ""
  printf '  %s%-16s %-8s %s%s\n' "${BOLD}" "TOOL" "STATUS" "NOTE" "${RESET}"
  echo "  ──────────────────────────────────────────────────────────"

  local name
  while IFS= read -r name; do
    _doctor_check_tool "${name}" required all_ok "${auto_install}"
  done < <(ctrl_tools_yaml | jq -r '.[] | select((.scope // "ctrl") == "ctrl" and .kind == "required") | .name')

  echo "  ──────────────────────────────────────────────────────────"
  while IFS= read -r name; do
    _doctor_check_tool "${name}" optional all_ok "${auto_install}"
  done < <(ctrl_tools_yaml | jq -r '.[] | select((.scope // "ctrl") == "ctrl" and (.kind // "optional") != "required") | .name')

  echo ""
  if [[ -n "${CTRL_CONFIG_FILE}" ]]; then
    _doctor_check_env_vars all_ok || true

    echo ""
    printf '  %s%-16s%s ' "${BOLD}" "ctrl.yaml" "${RESET}"
    if ctrl_check >/dev/null 2>&1; then
      printf '%s%-8s%s\n' "${GREEN}" "ok" "${RESET}"
    else
      printf '%s%-8s%s %s\n' "${RED}" "invalid" "${RESET}" "run 'ctrl check' for details"
      all_ok=0
    fi
  else
    printf '  %s%-16s%s %s\n' "${BOLD}" "ctrl.yaml" "${RESET}" "none found (project checks skipped)"
  fi

  echo ""
  if [[ "${all_ok}" == "1" ]]; then
    msg_ok "All checks passed"
  else
    msg_warn "Some checks failed. Run 'ctrl doctor --install' to install missing tools."
  fi
}

# _doctor_check_tool <name> <required|optional> <ok_var_name> <auto_install>
_doctor_check_tool() {
  local name="$1" kind="$2" ok_ref="$3" auto_install="$4"
  local why; why="$(ctrl_tool_field "${name}" '.why')"
  printf '  %-16s ' "${name}"

  if has_cmd "${name}"; then
    local min have
    min="$(ctrl_tool_field "${name}" '.min')"
    have="$(ctrl_tool_version "${name}")"
    if [[ -n "${min}" && -n "${have}" ]] && ! ctrl_version_ge "${have}" "${min}"; then
      printf '%s%-8s%s %s\n' "${RED}" "too old" "${RESET}" "have ${have}, need >= ${min} — ${why}"
      [[ "${kind}" == "required" ]] && printf -v "${ok_ref}" '%s' 0
      return
    fi
    printf '%s%-8s%s %s\n' "${GREEN}" "ok" "${RESET}" "${have:+${have} — }${why}"
    return
  fi

  if [[ "${kind}" == "required" ]]; then
    printf '%s%-8s%s' "${RED}" "missing" "${RESET}"
    printf -v "${ok_ref}" '%s' 0
  else
    printf '%s%-8s%s' "${YELLOW}" "missing" "${RESET}"
  fi
  local hint; hint="$(ctrl_install_hint "${name}")"
  printf ' %s%s\n' "${why}" "${hint:+  →  ${hint}}"

  if [[ "${auto_install}" == "1" && -n "${hint}" ]]; then
    msg "Installing ${name}: ${hint}"
    ctrl_install_tool "${name}" && msg_ok "${name} installed" || msg_warn "Failed to install ${name}"
  fi
}

_doctor_check_env_vars() {
  local ok_ref="$1"

  # Extract all ${VAR} and $VAR references from ctrl.yaml
  local -a vars=()
  while IFS= read -r var; do
    [[ -n "${var}" ]] && vars+=("${var}")
  done < <(grep -oE '\$(\{[A-Z_][A-Z0-9_]*\}|[A-Z_][A-Z0-9_]*)' "${CTRL_CONFIG_FILE}" 2>/dev/null | sed 's/[${}]//g' | sort -u || true)

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
      printf -v "${ok_ref}" '%s' 0
    fi
  done
}

# Remote machine check: OS, arch, and the tools ctrl needs on a deploy host.
_doctor_remote() {
  local target="$1"
  resolve_ssh_target "${target}"
  msg "Checking ${CTRL_MACHINE_NAME:-${target}} (${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST})"
  ctrl_ssh_run "$(cat <<'REMOTE'
printf '  %-16s %s\n' platform "$(uname -s)/$(uname -m)"
for t in docker rsync curl; do
  if command -v "$t" >/dev/null 2>&1; then printf '  %-16s ok\n' "$t"; else printf '  %-16s MISSING\n' "$t"; fi
done
if docker compose version >/dev/null 2>&1; then printf '  %-16s ok\n' "compose v2"; else printf '  %-16s MISSING (docker compose plugin)\n' "compose v2"; fi
if [ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null; then printf '  %-16s ok\n' "root/sudo"; else printf '  %-16s no passwordless sudo\n' "root/sudo"; fi
REMOTE
)"
}

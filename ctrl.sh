#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks without readlink -f (missing on older macOS).
_ctrl_self="${BASH_SOURCE[0]}"
while [[ -L "${_ctrl_self}" ]]; do
  _ctrl_link="$(readlink "${_ctrl_self}")"
  [[ "${_ctrl_link}" == /* ]] && _ctrl_self="${_ctrl_link}" || _ctrl_self="$(dirname "${_ctrl_self}")/${_ctrl_link}"
done
CTRL_SELF_DIR="$(cd "$(dirname "${_ctrl_self}")" && pwd -P)"
CTRL_BIN="${CTRL_SELF_DIR}/$(basename "${_ctrl_self}")"   # scripts call back into ctrl via this
unset _ctrl_self _ctrl_link

# ── Vendored ctrl detection ──────────────────────────────────────────────────
# A project can vendor its own ctrl version at vendor/ctrl/ or .ctrl/ next to
# ctrl.yaml. Callers (e.g. a project bootstrap script or wrapper) are
# responsible for resolving that path and invoking the vendored ctrl.sh
# directly — this script just exposes a probe for downstream tooling.
ctrl_find_vendored() {
  local start="${1:-${PWD}}"
  local dir="${start}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -f "${dir}/ctrl.yaml" ]]; then
      [[ -x "${dir}/vendor/ctrl/ctrl.sh" ]] && { echo "${dir}/vendor/ctrl/ctrl.sh"; return 0; }
      [[ -x "${dir}/.ctrl/ctrl.sh"       ]] && { echo "${dir}/.ctrl/ctrl.sh";       return 0; }
      return 1
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

source "${CTRL_SELF_DIR}/lib/core.sh"
source "${CTRL_SELF_DIR}/lib/services.sh"
source "${CTRL_SELF_DIR}/lib/deploy.sh"
source "${CTRL_SELF_DIR}/lib/remote.sh"
source "${CTRL_SELF_DIR}/lib/health.sh"
source "${CTRL_SELF_DIR}/lib/audit.sh"
source "${CTRL_SELF_DIR}/lib/ext.sh"
source "${CTRL_SELF_DIR}/lib/scripts.sh"
source "${CTRL_SELF_DIR}/lib/init.sh"
source "${CTRL_SELF_DIR}/lib/check.sh"
source "${CTRL_SELF_DIR}/lib/info.sh"
source "${CTRL_SELF_DIR}/lib/help.sh"
source "${CTRL_SELF_DIR}/lib/mcp.sh"
source "${CTRL_SELF_DIR}/lib/cp.sh"
source "${CTRL_SELF_DIR}/lib/doctor.sh"


# ── helpers ───────────────────────────────────────────────────────────────────
run_for_each() {
  local action="$1"; shift
  for svc in "$@"; do "${action}" "${svc}"; done
}

run_for_each_continue() {
  local action="$1"; shift
  local failed=0
  for svc in "$@"; do "${action}" "${svc}" || failed=1; done
  return "${failed}"
}

# Resolve optional deployment target from first arg (for deploy commands).
# If $1 is a known deployment name, resolves it and shifts CTRL_ARGS.
# Otherwise resolves the default deployment.
_resolve_target_and_services() {
  local -a args=("$@")
  if [[ "${#args[@]}" -gt 0 ]] && is_deployment_target "${args[0]}"; then
    resolve_deployment "${args[0]}"
    args=("${args[@]:1}")
  else
    resolve_deployment ""
  fi
  CTRL_SVC_ARGS=("${args[@]+"${args[@]}"}")
}

# Resolve optional SSH target from first arg (for ssh/rs/rl/env commands).
# First arg can be a deployment name (resolves machine) or a machine name.
_resolve_ssh_arg() {
  local -a args=("$@")
  if [[ "${#args[@]}" -gt 0 ]] && { is_deployment_target "${args[0]}" || is_machine "${args[0]}"; }; then
    resolve_ssh_target "${args[0]}"
    args=("${args[@]:1}")
  else
    resolve_machine ""
  fi
  CTRL_SVC_ARGS=("${args[@]+"${args[@]}"}")
}

# ── global flag parsing ───────────────────────────────────────────────────────
CTRL_FOLLOW=0
# Global flags are recognised anywhere, except after `run <name>`: from there
# on, arguments belong to the script (ctrl run parses its own modifiers).
_parse_global_flags() {
  local -a remaining=()
  local positionals=0
  while [[ "$#" -gt 0 ]]; do
    if [[ "${positionals}" -ge 2 && "${remaining[0]:-}" == "run" ]]; then
      remaining+=("$@"); break
    fi
    case "$1" in
      --dry-run|-n) CTRL_DRY_RUN=1 ;;
      --verbose|-v) CTRL_VERBOSE=1 ;;
      --json)       CTRL_JSON=1 ;;
      --config)     shift; CTRL_CONFIG_FILE="$1" ;;
      --follow)     CTRL_FOLLOW=1 ;;
      -*)           remaining+=("$1") ;;
      *)            remaining+=("$1"); positionals=$(( positionals + 1 )) ;;
    esac
    shift
  done
  CTRL_ARGS=("${remaining[@]+"${remaining[@]}"}")
}

_parse_global_flags "$@"
set -- "${CTRL_ARGS[@]+"${CTRL_ARGS[@]}"}"

# ── version / help (no config needed) ────────────────────────────────────────
case "${1:-}" in
  version|--version|-V)
    echo "ctrl v${CTRL_VERSION}"
    exit 0
    ;;
  completion)
    shift
    _shell="${1:-bash}"
    [[ "${_shell}" == "bash" || "${_shell}" == "zsh" ]] || { echo "No completion for shell: ${_shell}. Available: bash, zsh" >&2; exit 1; }
    # In the bundled dist, completion scripts are embedded as functions.
    if declare -f "_ctrl_embedded_completion_${_shell}" >/dev/null 2>&1; then
      "_ctrl_embedded_completion_${_shell}"
    else
      _comp_file="${CTRL_SELF_DIR}/completions/ctrl.${_shell}"
      [[ -f "${_comp_file}" ]] || { echo "No completion for shell: ${_shell}. Available: bash, zsh" >&2; exit 1; }
      cat "${_comp_file}"
    fi
    exit 0
    ;;
  help|--help|-h|"")
    _help_cmd="${2:-}"
    if [[ -n "${_help_cmd}" ]]; then
      # Per-command help — needs config, delegate after load
      shift 2 || true
      _CTRL_HELP_CMD="${_help_cmd}"
      _CTRL_HELP_MODE=1
    else
    ctrl_help_top
    exit 0
    fi
    ;;
esac

# ── mcp (no config needed for version, but mcp loads its own config) ─────────
if [[ "${1:-}" == "mcp" ]]; then
  ctrl_mcp_serve
  exit 0
fi

# ── init (no config needed) ───────────────────────────────────────────────────
if [[ "${1:-}" == "init" ]]; then
  _require_yq
  ctrl_init
  exit 0
fi


# ── upgrade (no config needed) ────────────────────────────────────────────────
if [[ "${1:-}" == "upgrade" ]]; then
  ctrl_upgrade
  exit 0
fi


# ── commands that need config ─────────────────────────────────────────────────
# run and doctor also work outside a project (bundled scripts, tool checks).
case "${1:-}" in run|doctor) CTRL_CONFIG_OPTIONAL=1 ;; esac
load_config
load_extensions

# Per-command help (ctrl help <cmd>) — needs config loaded for context
if [[ "${_CTRL_HELP_MODE:-0}" == "1" ]]; then
  show_command_help "${_CTRL_HELP_CMD:-}"
  exit 0
fi

CMD="${1:-}"; shift || true
CTRL_SVC_ARGS=()

case "${CMD}" in

  # ── list ─────────────────────────────────────────────────────────────────
  list|ls)
    case "${1:-services}" in
      machines|m) ctrl_list_machines ;;
      services|s)
        if [[ "${CTRL_JSON}" == "1" ]]; then
          ctrl_list_json
        else
          printf '%s%-20s %-10s %-12s %s%s\n' "${BOLD}" "SERVICE" "KIND" "BUILD" "IMAGE:TAG" "${RESET}"
          while IFS= read -r svc; do
            local_kind="$(ctrl_service_kind "${svc}")"
            local_tool="$(ctrl_service_field "${svc}" '.build.tool // "—"')"
            [[ "${local_kind}" == "external" ]] && local_tool="—"
            svc_img="$(ctrl_service_field "${svc}" '.image // "-"'):$(ctrl_service_field "${svc}" '.tag // "latest"')"
            printf '  %-20s %-10s %-12s %s\n' "${svc}" "${local_kind}" "${local_tool}" "${svc_img}"
          done < <(ctrl_service_names)
        fi
        ;;
      *) fail "Usage: ctrl list [services|machines]   (scripts: ctrl run)" ;;
    esac
    ;;

  # ── build ────────────────────────────────────────────────────────────────
  build|b)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl b <svc|all>"
    _svc_out="$(ctrl_resolve_services "$@")" || exit 1
    read -r -a svcs <<< "${_svc_out}"
    with_journal "build" "${svcs[*]}" run_for_each build_code_service "${svcs[@]}"
    ;;

  # ── image ────────────────────────────────────────────────────────────────
  image|i)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl i <svc|all>"
    _svc_out="$(ctrl_resolve_services "$@")" || exit 1
    read -r -a svcs <<< "${_svc_out}"
    with_journal "image" "${svcs[*]}" run_for_each build_image_service "${svcs[@]}"
    ;;

  # ── push ─────────────────────────────────────────────────────────────────
  push|p)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl p <svc|all>"
    _svc_out="$(ctrl_resolve_services "$@")" || exit 1
    read -r -a svcs <<< "${_svc_out}"
    with_journal "push" "${svcs[*]}" run_for_each push_image_service "${svcs[@]}"
    ;;

  # ── release ──────────────────────────────────────────────────────────────
  release|r)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl r <svc|all>"
    _svc_out="$(ctrl_resolve_services "$@")" || exit 1
    read -r -a svcs <<< "${_svc_out}"
    with_journal "release" "${svcs[*]}" run_for_each release_service "${svcs[@]}"
    ;;

  # ── sync ─────────────────────────────────────────────────────────────────
  sync|s)
    _resolve_target_and_services "$@"
    with_journal "sync" "${CTRL_DEPLOY_NAME}" sync_files
    ;;

  # ── deploy [--release] [--sync] [target] [svc|all] ───────────────────────
  deploy|d)
    _deploy_release=0; _deploy_sync=0; _deploy_args=()
    for _a in "$@"; do
      case "${_a}" in
        --release) _deploy_release=1 ;;
        --sync)    _deploy_sync=1 ;;
        -*)        fail "Unknown flag: ${_a}. Usage: ctrl deploy [--release] [--sync] [target] [svc|all]" ;;
        *)         _deploy_args+=("${_a}") ;;
      esac
    done
    _resolve_target_and_services "${_deploy_args[@]+"${_deploy_args[@]}"}"
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      _svc_out="$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")" || exit 1
    else
      _svc_out="$(ctrl_resolve_services all)" || exit 1
    fi
    read -r -a svcs <<< "${_svc_out}"
    _deploy_cmd="deploy"
    [[ "${_deploy_release}" == "1" ]] && { _deploy_cmd+=" --release"; run_for_each release_service "${svcs[@]}"; }
    [[ "${_deploy_sync}" == "1" ]]    && { _deploy_cmd+=" --sync"; sync_files; }
    with_journal "${_deploy_cmd}" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── ssh ──────────────────────────────────────────────────────────────────
  ssh)
    _resolve_ssh_arg "$@"
    while [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 && "${CTRL_SVC_ARGS[0]}" == "--" ]]; do
      CTRL_SVC_ARGS=("${CTRL_SVC_ARGS[@]:1}")
    done
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      with_journal "ssh" "${CTRL_MACHINE_NAME}:${CTRL_SVC_ARGS[*]}" ctrl_ssh_run "${CTRL_SVC_ARGS[*]}"
    else
      with_journal "ssh" "${CTRL_MACHINE_NAME}" open_ssh
    fi
    ;;

  # ── remote-status ────────────────────────────────────────────────────────
  remote-status|rs)
    _resolve_ssh_arg "$@"
    with_journal "remote-status" "${CTRL_MACHINE_NAME}:${CTRL_SVC_ARGS[0]:-}" remote_status "${CTRL_SVC_ARGS[0]:-}"
    ;;

  # ── remote-logs ──────────────────────────────────────────────────────────
  remote-logs|rl)
    _resolve_ssh_arg "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl rl [target] <svc> [lines]"
    with_journal "remote-logs" "${CTRL_MACHINE_NAME}:${CTRL_SVC_ARGS[0]}" remote_logs "${CTRL_SVC_ARGS[0]}" "${CTRL_SVC_ARGS[1]:-200}"
    ;;

  # ── env (container environment) ──────────────────────────────────────────
  env|e)
    _resolve_ssh_arg "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl env [target] <svc>"
    with_journal "env" "${CTRL_MACHINE_NAME}:${CTRL_SVC_ARGS[0]}" remote_env "${CTRL_SVC_ARGS[0]}"
    ;;

  # ── hc: health, wait, latency, tcp — services and machines ──────────────
  health-check|hc)
    with_journal "health-check" "$*" ctrl_hc "$@"
    ;;

  # ── run: every script, local or on any set of hosts ─────────────────────
  run)
    ctrl_run "$@"
    ;;

  # ── drift detection ──────────────────────────────────────────────────────
  diff)
    _resolve_target_and_services "$@"
    with_journal "diff" "${CTRL_DEPLOY_NAME}" diff_deployment
    ;;

  # ── info ─────────────────────────────────────────────────────────────────
  info)
    ctrl_info "${1:-}"
    ;;

  # ── check ────────────────────────────────────────────────────────────────
  check|c)
    with_journal "check" "" ctrl_check
    ;;

  # ── set tag|default ──────────────────────────────────────────────────────
  set)
    case "${1:-}" in
      tag)
        [[ "$#" -ge 3 ]] || fail "Usage: ctrl set tag <svc> <tag>"
        with_journal "set tag" "$2:$3" ctrl_set_tag "$2" "$3"
        ;;
      default)
        [[ "$#" -ge 2 ]] || fail "Usage: ctrl set default <machine|deployment>"
        with_journal "set default" "$2" ctrl_set_default "$2"
        ;;
      *) fail "Usage: ctrl set tag <svc> <tag>  |  ctrl set default <machine|deployment>" ;;
    esac
    ;;

  # ── history ──────────────────────────────────────────────────────────────
  history|h)
    show_history "${1:-20}"
    ;;

  version)
    echo "ctrl v${CTRL_VERSION}"
    ;;

  # ── cp ───────────────────────────────────────────────────────────────────
  cp)
    [[ "$#" -ge 2 ]] || fail "Usage: ctrl cp [--exclude PAT] [--delete] [--progress] <src> <dst>"
    ctrl_cp "$@"
    ;;

  # ── doctor ───────────────────────────────────────────────────────────────
  doctor)
    ctrl_doctor "$@"
    ;;

  # ── upgrade ──────────────────────────────────────────────────────────────
  upgrade)
    ctrl_upgrade
    ;;

  # ── extension commands ────────────────────────────────────────────────────
  *)
    # Extensions define ctrl_ext_cmd_<name> (legacy: ctrl_cmd_<name>)
    _ext_fn="ctrl_ext_cmd_${CMD//-/_}"
    ctrl_is_valid_name "${CMD}" && ! declare -f "${_ext_fn}" >/dev/null 2>&1 && _ext_fn="ctrl_cmd_${CMD//-/_}"
    if ctrl_is_valid_name "${CMD}" && declare -f "${_ext_fn}" >/dev/null 2>&1; then
      "${_ext_fn}" "$@"
    elif _moved="$(ctrl_moved_command "${CMD}")"; then
      fail "'ctrl ${CMD}' was removed in ctrl 0.4 — use: ${_moved}"
    else
      fail "Unknown command: ${CMD}. Run 'ctrl help' for usage."
    fi
    ;;
esac

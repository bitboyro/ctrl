#!/usr/bin/env bash
set -euo pipefail

CTRL_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ── Vendored ctrl detection ──────────────────────────────────────────────────
# A project can vendor its own ctrl version at vendor/ctrl/ or .ctrl/ next to
# ctrl.yaml. Callers (e.g. a project bootstrap script or wrapper) are
# responsible for resolving that path and invoking the vendored ctrl.sh
# directly — this script just exposes a probe for downstream tooling.
ctrl_find_vendored() {
  local start="${1:-${PWD}}" dir="${start}"
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
source "${CTRL_SELF_DIR}/lib/gitlab.sh"
source "${CTRL_SELF_DIR}/lib/templates.sh"
source "${CTRL_SELF_DIR}/lib/init.sh"
source "${CTRL_SELF_DIR}/lib/check.sh"
source "${CTRL_SELF_DIR}/lib/info.sh"
source "${CTRL_SELF_DIR}/lib/mcp.sh"
source "${CTRL_SELF_DIR}/lib/cp.sh"
source "${CTRL_SELF_DIR}/lib/probe.sh"
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
_parse_global_flags() {
  local -a remaining=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run|-n) CTRL_DRY_RUN=1 ;;
      --verbose|-v) CTRL_VERBOSE=1 ;;
      --json)       CTRL_JSON=1 ;;
      --config)     shift; CTRL_CONFIG_FILE="$1" ;;
      --follow)     CTRL_FOLLOW=1 ;;
      *)            remaining+=("$1") ;;
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
    _comp_file="${CTRL_SELF_DIR}/completions/ctrl.${_shell}"
    [[ -f "${_comp_file}" ]] || { echo "No completion for shell: ${_shell}. Available: bash, zsh" >&2; exit 1; }
    cat "${_comp_file}"
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
    cat <<'HELPEOF'
CTRL_HELP_MARKER
HELPEOF
    _ver_line="ctrl v${CTRL_VERSION} — YAML-driven platform operations CLI"
    cat <<EOF
${_ver_line}

Usage: ctrl [flags] <command> [args]
       ctrl help <command>    per-command help with examples

Quick start:
  ctrl init             # generate ctrl.yaml for this project
  ctrl check            # validate the config
  ctrl list             # see all services

Build pipeline:
  b  / build   <svc|all>             Build service code locally
  i  / image   <svc|all>             Build Docker image (no push)
  p  / push    <svc|all>             Push image to registry
  r  / release <svc|all>             build + image + push

  Example: ctrl release api          # build + image + push for api

Deploy pipeline:
  d  / deploy    [target] [svc|all]  Pull + start on deployment target
  rd / redeploy  [target] [svc|all]  release + deploy in one step
  s  / sync      [target]            Sync files to target
  sd / sync-deploy [target] [svc|all] sync + deploy

  Example: ctrl diff                 # check drift before deploying
           ctrl deploy prod api      # deploy api to prod

Remote:
  ssh              [target] [-- cmd] Interactive SSH or run remote command
  rs / remote-status [target] [svc]  docker compose ps
  rl / remote-logs   [target] <svc>  docker compose logs  (--follow to tail)
  e  / env           [target] <svc>  Show env of running container

  Example: ctrl rl api --follow      # tail api logs on default machine

Health & tests:
  hc / health-check [svc|all]        Health check
  wr / wait-ready   <svc> [timeout]  Wait until healthy
  st / smoke-test   [svc|all]        Run smoke tests

Scripts:
  run            <name> [args]       Run a named script
  script init    <name>              Create script from template + register
  sc / scripts                       List scripts

Diagnostics:
  ping           <svc|machine>       HTTP / TCP ping with latency stats
  call           <svc> <path>        Authenticated REST call
  probe          [svc] [--tcp]       HTTP or TCP connectivity check
  probe sniff    <svc>               Live tcpdump via ctrl-tools container
  probe shell                        Interactive ctrl-tools container shell
  doctor         [--install]         Pre-flight dep check with install hints

Config & info:
  init                               Interactive wizard — generate ctrl.yaml
  c  / check    [--json]             Validate ctrl.yaml
  ls / list                          List all services with kind + image:tag
  info          [machine|svc]        Project / machine / service detail
  m  / machines                      List machines
  diff          [target] [--json]    Declared vs running image:tag (drift)
  t  / tag      <svc> <newtag>       Update service tag in ctrl.yaml
  default       <name>               Set machines.default or deployments.default
  h  / history  [n]                  Last n journal entries (default 20)
  mcp                                Start stdio MCP server (JSON-RPC 2.0)
  completion    <bash|zsh>           Print shell completion script

Global flags:
  -n  --dry-run        Print commands, no execution
  -v  --verbose        Extra debug output
      --json           JSON output (list, hc, info, diff, check, sc, machines)
      --config <path>  Override ctrl.yaml location
      --follow         Tail logs (with rl)

Deps: yq jq curl ssh docker rsync   Run 'ctrl doctor' to verify.

[target] is a deployment or machine name. Omit to use the configured default.

EOF
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

# ── commands that need config ─────────────────────────────────────────────────
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

  # ── GitLab ───────────────────────────────────────────────────────────────
  gitlab-project-info)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl gitlab-project-info <project-id-or-path>"
    ctrl_gitlab_project_info "$1"
    ;;

  gitlab-runner-deploy)
    ctrl_gitlab_runner_deploy
    ;;

  # ── list ─────────────────────────────────────────────────────────────────
  list|ls)
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

  # ── build ────────────────────────────────────────────────────────────────
  build|b)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl b <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "build" "${svcs[*]}" run_for_each build_code_service "${svcs[@]}"
    ;;

  # ── image ────────────────────────────────────────────────────────────────
  image|i)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl i <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "image" "${svcs[*]}" run_for_each build_image_service "${svcs[@]}"
    ;;

  # ── push ─────────────────────────────────────────────────────────────────
  push|p)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl p <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "push" "${svcs[*]}" run_for_each push_image_service "${svcs[@]}"
    ;;

  # ── release ──────────────────────────────────────────────────────────────
  release|r)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl r <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "release" "${svcs[*]}" run_for_each release_service "${svcs[@]}"
    ;;

  # ── sync ─────────────────────────────────────────────────────────────────
  sync|s)
    _resolve_target_and_services "$@"
    with_journal "sync" "${CTRL_DEPLOY_NAME}" sync_files
    ;;

  # ── deploy ───────────────────────────────────────────────────────────────
  deploy|d)
    _resolve_target_and_services "$@"
    local _svc_out
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      _svc_out="$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")" || exit 1
    else
      _svc_out="$(ctrl_resolve_services all)" || exit 1
    fi
    read -r -a svcs <<< "${_svc_out}"
    with_journal "deploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── redeploy ─────────────────────────────────────────────────────────────
  redeploy|rd)
    _resolve_target_and_services "$@"
    local _svc_out
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      _svc_out="$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")" || exit 1
    else
      _svc_out="$(ctrl_resolve_services all)" || exit 1
    fi
    read -r -a svcs <<< "${_svc_out}"
    run_for_each release_service "${svcs[@]}"
    with_journal "redeploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── sync-deploy ──────────────────────────────────────────────────────────
  sync-deploy|sd)
    _resolve_target_and_services "$@"
    local _svc_out
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      _svc_out="$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")" || exit 1
    else
      _svc_out="$(ctrl_resolve_services all)" || exit 1
    fi
    read -r -a svcs <<< "${_svc_out}"
    sync_files
    with_journal "sync-deploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
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

  # ── env (was inspect) ────────────────────────────────────────────────────
  env|e)
    _resolve_ssh_arg "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl env [target] <svc>"
    with_journal "env" "${CTRL_MACHINE_NAME}:${CTRL_SVC_ARGS[0]}" remote_env "${CTRL_SVC_ARGS[0]}"
    ;;

  # ── health-check ─────────────────────────────────────────────────────────
  health-check|hc)
    resolve_deployment "" 2>/dev/null || true
    svcs=()
    if [[ "$#" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_health_services "$@")"
    else
      read -r -a svcs <<< "$(ctrl_health_target_names)"
    fi
    with_journal "health-check" "${svcs[*]}" run_for_each_continue health_check_service "${svcs[@]}"
    ;;

  # ── wait-ready ───────────────────────────────────────────────────────────
  wait-ready|wr)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl wr <svc> [timeout]"
    with_journal "wait-ready" "$1" wait_ready_service "$1" "${2:-60}"
    ;;

  # ── smoke-test ───────────────────────────────────────────────────────────
  smoke-test|st)
    if [[ "$#" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    with_journal "smoke-test" "${svcs[*]}" smoke_test_services "${svcs[@]}"
    ;;

  # ── run script ───────────────────────────────────────────────────────────
  run)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl run <name> [args]"
    _script_name="$1"; shift
    with_journal "run" "${_script_name}" run_script "${_script_name}" "$@"
    ;;

  # ── script subcommands ───────────────────────────────────────────────────
  script)
    case "${1:-}" in
      init)
        shift
        [[ "$#" -ge 1 ]] || fail "Usage: ctrl script init <name>"
        ctrl_script_init "$1"
        ;;
      ""|list)
        printf '%s%-24s %s%s\n' "${BOLD}" "SCRIPT" "DESCRIPTION" "${RESET}"
        list_scripts
        ;;
      *)
        fail "Unknown script subcommand: $1. Use: ctrl script init <name>"
        ;;
    esac
    ;;

  # ── list scripts ─────────────────────────────────────────────────────────
  scripts|sc)
    _filter_tag=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tag) shift; _filter_tag="${1:-}"; shift ;;
        *)     shift ;;
      esac
    done
    printf '%s%-24s %s%s\n' "${BOLD}" "SCRIPT" "DESCRIPTION" "${RESET}"
    list_scripts "${_filter_tag}"
    ;;

  # ── machines ─────────────────────────────────────────────────────────────
  machines|m)
    ctrl_list_machines
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

  # ── tag ──────────────────────────────────────────────────────────────────
  tag|t)
    [[ "$#" -ge 2 ]] || fail "Usage: ctrl tag <svc> <tag>"
    with_journal "tag" "$1:$2" ctrl_set_tag "$1" "$2"
    ;;

  # ── default ──────────────────────────────────────────────────────────────
  default)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl default <name>"
    with_journal "default" "$1" ctrl_set_default "$1"
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

  # ── ping ─────────────────────────────────────────────────────────────────
  ping)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl ping <svc|machine> [--n <count>] [--interval <s>]"
    ctrl_ping "$@"
    ;;

  # ── call ─────────────────────────────────────────────────────────────────
  call)
    [[ "$#" -ge 2 ]] || fail "Usage: ctrl call <svc> <path> [--method GET|POST|PUT|DELETE] [--body '{}'] [--header 'K: V']"
    ctrl_call "$@"
    ;;

  # ── probe ────────────────────────────────────────────────────────────────
  probe)
    ctrl_probe "$@"
    ;;

  # ── doctor ───────────────────────────────────────────────────────────────
  doctor)
    ctrl_doctor "$@"
    ;;

  # ── extension commands ────────────────────────────────────────────────────
  *)
    _ext_fn="ctrl_cmd_${CMD//-/_}"
    if declare -f "${_ext_fn}" >/dev/null 2>&1; then
      "${_ext_fn}" "$@"
    else
      fail "Unknown command: ${CMD}. Run 'ctrl help' for usage."
    fi
    ;;
esac

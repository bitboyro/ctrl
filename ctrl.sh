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
  help|--help|-h|"")
    cat <<EOF
ctrl v${CTRL_VERSION} — YAML-driven platform operations CLI

Usage: ctrl [--dry-run] [--verbose] [--json] [--config <path>] <command> [args]

Build pipeline:
  build  / b    <svc|all>            Build service code locally
  image  / i    <svc|all>            Build Docker image (no push)
  push   / p    <svc|all>            Push image to registry
  release/ r    <svc|all>            build + image + push

Deploy pipeline:
  deploy  / d   [target] [svc|all]   Pull + start services on deployment target
  redeploy/ rd  [target] [svc|all]   release + deploy
  sync    / s   [target]             Sync files to deployment target
  sync-deploy/sd [target] [svc|all]  sync + deploy

Remote:
  ssh           [target] [cmd]       Interactive SSH or run a remote command
  remote-status/rs [target] [svc]   docker compose ps
  remote-logs/rl   [target] <svc> [n] docker compose logs (--follow to tail)
  env          / e  [target] <svc>   Show env of running container

Health:
  health-check / hc  [svc|all]       Health check
  wait-ready   / wr  <svc> [timeout] Wait until healthy
  smoke-test   / st  [svc|all]       Run smoke tests

Scripts:
  run           <name> [args]        Run a named script
  script        [list]               List scripts
  script        init <name>          Create script from template, register in ctrl.yaml
  scripts       / sc                 List scripts

Config & info:
  init                               Interactive wizard — generate ctrl.yaml
  check         / c [--json]         Validate ctrl.yaml
  list          / ls                 List all services
  info          [machine|svc]        Show project / machine / service detail
  machines      / m                  List all machines
  diff          [target] [--json]    Declared vs running image:tag (drift)
  tag           / t <svc> <tag>      Update service tag in ctrl.yaml
  default       <name>               Set machines.default or deployments.default

Audit:
  history       / h   [n]            Last n journal entries (default 20)
  version                            Print ctrl version

MCP:
  mcp                                Start stdio MCP server (JSON-RPC 2.0)

Global flags:
  --dry-run  -n    Print commands, no execution
  --verbose  -v    Extra debug output
  --json           JSON output (supported by: list, hc, info, diff, check, sc, machines)
  --config <path>  Override ctrl.yaml location
  --follow         Tail logs (with rl)

[target] is a deployment name (for deploy commands) or machine name (for SSH commands).
When omitted, deployments.default / machines.default is used.

EOF
    exit 0
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
      ctrl_ssh_run "${CTRL_SVC_ARGS[*]}"
    else
      open_ssh
    fi
    ;;

  # ── remote-status ────────────────────────────────────────────────────────
  remote-status|rs)
    _resolve_ssh_arg "$@"
    remote_status "${CTRL_SVC_ARGS[0]:-}"
    ;;

  # ── remote-logs ──────────────────────────────────────────────────────────
  remote-logs|rl)
    _resolve_ssh_arg "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl rl [target] <svc> [lines]"
    remote_logs "${CTRL_SVC_ARGS[0]}" "${CTRL_SVC_ARGS[1]:-200}"
    ;;

  # ── env (was inspect) ────────────────────────────────────────────────────
  env|e)
    _resolve_ssh_arg "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl env [target] <svc>"
    remote_env "${CTRL_SVC_ARGS[0]}"
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
    run_for_each_continue health_check_service "${svcs[@]}"
    ;;

  # ── wait-ready ───────────────────────────────────────────────────────────
  wait-ready|wr)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl wr <svc> [timeout]"
    wait_ready_service "$1" "${2:-60}"
    ;;

  # ── smoke-test ───────────────────────────────────────────────────────────
  smoke-test|st)
    if [[ "$#" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    smoke_test_services "${svcs[@]}"
    ;;

  # ── run script ───────────────────────────────────────────────────────────
  run)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl run <name> [args]"
    _script_name="$1"; shift
    run_script "${_script_name}" "$@"
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
    diff_deployment
    ;;

  # ── info ─────────────────────────────────────────────────────────────────
  info)
    ctrl_info "${1:-}"
    ;;

  # ── check ────────────────────────────────────────────────────────────────
  check|c)
    ctrl_check
    ;;

  # ── tag ──────────────────────────────────────────────────────────────────
  tag|t)
    [[ "$#" -ge 2 ]] || fail "Usage: ctrl tag <svc> <tag>"
    ctrl_set_tag "$1" "$2"
    ;;

  # ── default ──────────────────────────────────────────────────────────────
  default)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl default <name>"
    ctrl_set_default "$1"
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

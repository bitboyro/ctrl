#!/usr/bin/env bash
set -euo pipefail

CTRL_SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

source "${CTRL_SELF_DIR}/lib/core.sh"
source "${CTRL_SELF_DIR}/lib/services.sh"
source "${CTRL_SELF_DIR}/lib/deploy.sh"
source "${CTRL_SELF_DIR}/lib/remote.sh"
source "${CTRL_SELF_DIR}/lib/health.sh"
source "${CTRL_SELF_DIR}/lib/audit.sh"

source "${CTRL_SELF_DIR}/lib/ext.sh"
source "${CTRL_SELF_DIR}/lib/gitlab.sh"

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

# Resolve optional deployment target from first arg.
# If $1 is a known deployment name, sets it and shifts CTRL_ARGS.
# Otherwise uses the default target. Remaining CTRL_ARGS are service selectors.
_resolve_target_and_services() {
  local -a args=("$@")
  if [[ "${#args[@]}" -gt 0 ]] && is_deployment_target "${args[0]}"; then
    resolve_deployment "${args[0]}"
    args=("${args[@]:1}")
  else
    resolve_deployment ""
  fi
  # Return remaining args as services (caller reads CTRL_SVC_ARGS)
  CTRL_SVC_ARGS=("${args[@]+"${args[@]}"}")
}

# ── global flag parsing ───────────────────────────────────────────────────────
CTRL_FOLLOW=0
_parse_global_flags() {
  local -a remaining=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)    CTRL_DRY_RUN=1 ;;
      --verbose|-v) CTRL_VERBOSE=1 ;;
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

Usage: ctrl [--dry-run] [--verbose] [--config <path>] <command> [args]

Service commands:
  list  / ls                        List services defined in ctrl.yaml
  build / b    <svc|all>            Build service code locally
  image / i    <svc|all>            Build Docker image (no push)
  push  / pu   <svc|all>            Push image to registry
  rel          <svc|all>            build + image + push
  dep          [target] [svc|all]   Pull and start on deployment target (default: deployments.default)
  rdep         [target] [svc|all]   rel + dep

Deployment commands:
  sync         [target]             Sync files to deployment target
  dep          [target] [svc|all]   Pull + start services on target
  rdep         [target] [svc|all]   rel + dep on target

Remote commands:
  ssh / sr     [target] [cmd]        Interactive SSH or run a remote command
  rs           [svc]                Remote status (docker compose ps)
  rl           <svc> [lines]        Remote logs (--follow to tail)
  insp         <svc>                Show env of running container

Health commands:
  hc           [svc|all]            Health check
  wr           <svc> [timeout]      Wait until healthy
  st           [svc|all]            Smoke test

Script commands:
  run          <name> [args]        Run a named script
  scripts      / sc                 List scripts

Audit:
  hist         [n]                  Last n journal entries (default 20)
  plan                              Dry-run mode (alias for --dry-run)
  version                           Print ctrl version

Global flags:
  --dry-run    -n                   Print commands, no execution
  --verbose    -v                   Extra debug output
  --config     <path>               Override ctrl.yaml location
  --follow                          Tail logs (with rl)

Deployment targets are defined under deployments: in ctrl.yaml.
When [target] is omitted, deployments.default is used.

EOF
    exit 0
    ;;
esac

# ── commands that need config ─────────────────────────────────────────────────
load_config
load_extensions

CMD="${1:-}"; shift || true
CTRL_SVC_ARGS=()

case "${CMD}" in

  # ── GitLab project info ───────────────────────────────────────────────
  gitlab-project-info)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl gitlab-project-info <project-id-or-path>"
    ctrl_gitlab_project_info "$1"
    ;;

  # ── GitLab runner deploy ──────────────────────────────────────────────
  gitlab-runner-deploy)
    ctrl_gitlab_runner_deploy
    ;;

  # ── list ──────────────────────────────────────────────────────────────────
  list|ls)
    printf '%s%-20s %-40s %s%s\n' "${BOLD}" "SERVICE" "DESCRIPTION" "IMAGE:TAG" "${RESET}"
    while IFS= read -r svc; do
      svc_img="$(ctrl_service_field "${svc}" '.image // "-"'):$(ctrl_service_field "${svc}" '.tag // "latest"')"
      svc_desc="$(ctrl_service_field "${svc}" '.description // ""')"
      printf '  %-20s %-40s %s\n' "${svc}" "${svc_desc}" "${svc_img}"
    done < <(ctrl_service_names)
    ;;

  # ── build ─────────────────────────────────────────────────────────────────
  build|b)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl b <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "build" "${svcs[*]}" run_for_each build_code_service "${svcs[@]}"
    ;;

  # ── image ─────────────────────────────────────────────────────────────────
  image|i)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl i <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "image" "${svcs[*]}" run_for_each build_image_service "${svcs[@]}"
    ;;

  # ── push ──────────────────────────────────────────────────────────────────
  push|pu)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl pu <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "push" "${svcs[*]}" run_for_each push_image_service "${svcs[@]}"
    ;;

  # ── release ───────────────────────────────────────────────────────────────
  release|rel)
    [[ "$#" -gt 0 ]] || fail "Usage: ctrl rel <svc|all>"
    read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    with_journal "release" "${svcs[*]}" run_for_each release_service "${svcs[@]}"
    ;;

  # ── sync ──────────────────────────────────────────────────────────────────
  sync)
    _resolve_target_and_services "$@"
    with_journal "sync" "${CTRL_DEPLOY_NAME}" sync_files
    ;;

  # ── deploy ────────────────────────────────────────────────────────────────
  deploy|dep)
    _resolve_target_and_services "$@"
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    with_journal "deploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── redeploy ──────────────────────────────────────────────────────────────
  redeploy|rdep)
    _resolve_target_and_services "$@"
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    run_for_each release_service "${svcs[@]}"
    with_journal "redeploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── sync + deploy ─────────────────────────────────────────────────────────
  sync-deploy|sdep)
    _resolve_target_and_services "$@"
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    sync_files
    with_journal "sync-deploy" "${CTRL_DEPLOY_NAME}:${svcs[*]}" deploy_services "${svcs[@]}"
    ;;

  # ── ssh / sr ──────────────────────────────────────────────────────────────
  ssh|sr)
    _resolve_target_and_services "$@"
    # strip leading '--' option-separator that users sometimes include
    while [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 && "${CTRL_SVC_ARGS[0]}" == "--" ]]; do
      CTRL_SVC_ARGS=("${CTRL_SVC_ARGS[@]:1}")
    done
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      ctrl_ssh_run "${CTRL_SVC_ARGS[*]}"
    else
      open_ssh
    fi
    ;;

  # ── remote-status ─────────────────────────────────────────────────────────
  remote-status|rs)
    _resolve_target_and_services "$@"
    remote_status "${CTRL_SVC_ARGS[0]:-}"
    ;;

  # ── remote-logs ───────────────────────────────────────────────────────────
  remote-logs|rl)
    _resolve_target_and_services "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl rl [target] <svc> [lines]"
    remote_logs "${CTRL_SVC_ARGS[0]}" "${CTRL_SVC_ARGS[1]:-200}"
    ;;

  # ── inspect ───────────────────────────────────────────────────────────────
  inspect|insp)
    _resolve_target_and_services "$@"
    [[ "${#CTRL_SVC_ARGS[@]}" -ge 1 ]] || fail "Usage: ctrl insp [target] <svc>"
    remote_inspect "${CTRL_SVC_ARGS[0]}"
    ;;

  # ── health-check ──────────────────────────────────────────────────────────
  health-check|hc)
    _resolve_target_and_services "$@"
    svcs=()
    if [[ "${#CTRL_SVC_ARGS[@]}" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "${CTRL_SVC_ARGS[@]}")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    run_for_each_continue health_check_service "${svcs[@]}"
    ;;

  # ── wait-ready ────────────────────────────────────────────────────────────
  wait-ready|wr)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl wr <svc> [timeout]"
    wait_ready_service "$1" "${2:-60}"
    ;;

  # ── smoke-test ────────────────────────────────────────────────────────────
  smoke-test|st)
    if [[ "$#" -gt 0 ]]; then
      read -r -a svcs <<< "$(ctrl_resolve_services "$@")"
    else
      read -r -a svcs <<< "$(ctrl_resolve_services all)"
    fi
    smoke_test_services "${svcs[@]}"
    ;;

  # ── run script ────────────────────────────────────────────────────────────
  run)
    [[ "$#" -ge 1 ]] || fail "Usage: ctrl run <name> [args]"
    _script_name="$1"; shift
    run_script "${_script_name}" "$@"
    ;;

  # ── list scripts ──────────────────────────────────────────────────────────
  scripts|sc)
    printf '%s%-24s %s%s\n' "${BOLD}" "SCRIPT" "DESCRIPTION" "${RESET}"
    list_scripts
    ;;

  # ── history ───────────────────────────────────────────────────────────────
  history|hist)
    show_history "${1:-20}"
    ;;

  # ── plan / dry-run ────────────────────────────────────────────────────────
  plan)
    CTRL_DRY_RUN=1
    msg "Dry-run mode — no changes will be made. Use --dry-run on any command for the same effect."
    ;;

  version)
    echo "ctrl v${CTRL_VERSION}"
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

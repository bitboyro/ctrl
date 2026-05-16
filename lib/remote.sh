#!/usr/bin/env bash
# remote.sh — ssh, remote-status, remote-logs, env (container environment)

open_ssh() {
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  local target; target="${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}"
  local port="${CTRL_META_SSH_PORT}"
  local cmd="cd $(printf '%q' "${remote_dir}") && exec \${SHELL:-bash} -l"

  local -a flags=(-t -p "${port}" -o StrictHostKeyChecking=accept-new)
  [[ -n "${CTRL_META_SSH_KEY}" ]] && flags+=(-i "${CTRL_META_SSH_KEY}")

  if [[ -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    has_cmd sshpass || fail "sshpass required for password-based auth. Install: brew install sshpass / apt-get install sshpass"
    sshpass -p "${CTRL_META_SSH_PASSWORD}" ssh "${flags[@]}" "${target}" "${cmd}"
  else
    ssh "${flags[@]}" "${target}" "${cmd}"
  fi
}

remote_status() {
  local svc="${1:-}"
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  if [[ -n "${svc}" ]]; then
    local cs; cs="$(_svc_compose_service "${svc}")"
    ctrl_ssh_run "cd $(printf '%q' "${remote_dir}") && docker compose ps ${cs}"
  else
    ctrl_ssh_run "cd $(printf '%q' "${remote_dir}") && docker compose ps"
  fi
}

remote_logs() {
  local svc="$1"
  local lines="${2:-200}"
  local follow="${CTRL_FOLLOW:-0}"
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local cs; cs="$(_svc_compose_service "${svc}")"
  local tail_flag="--tail ${lines}"
  local follow_flag=""
  [[ "${follow}" == "1" ]] && follow_flag="--follow"
  ctrl_ssh_run "cd $(printf '%q' "${remote_dir}") && docker compose logs ${tail_flag} ${follow_flag} ${cs}"
}

remote_env() {
  local svc="$1"
  ctrl_service_exists "${svc}" || fail "Unknown service: ${svc}"
  local cs; cs="$(_svc_compose_service "${svc}")"
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  ctrl_ssh_run "cd $(printf '%q' "${remote_dir}") && docker compose exec ${cs} env | sort"
}

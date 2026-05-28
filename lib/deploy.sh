#!/usr/bin/env bash
# deploy.sh — deployment target resolution, sync, deploy, drift detection

CTRL_DEPLOY_NAME=""
CTRL_DEPLOY_SYNC_PATHS=()

# ── deployment resolution ─────────────────────────────────────────────────────
# Finds a deployment target by name, resolves its machine (sets CTRL_META_SSH_*),
# then sets compose path and sync paths.

resolve_deployment() {
  local target_name="${1:-}"

  # env var override takes highest priority
  [[ -n "${CTRL_DEPLOYMENT:-}" ]] && target_name="${CTRL_DEPLOYMENT}"

  if [[ -z "${target_name}" ]]; then
    target_name="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
    [[ -n "${target_name}" && "${target_name}" != "null" ]] || \
      fail "No deployment target specified and no deployments.default set in ctrl.yaml"
  fi

  local found; found="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]] || \
    fail "Deployment target '${target_name}' not found in ctrl.yaml deployments.targets"

  CTRL_DEPLOY_NAME="${target_name}"

  # Resolve the machine referenced by this deployment
  local machine_name; machine_name="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .machine // \"\"")"
  if [[ -n "${machine_name}" && "${machine_name}" != "null" ]]; then
    resolve_machine "${machine_name}"
  fi

  # Allow inline SSH overrides on a deployment target (backwards compat / staging)
  local t_ssh_host t_ssh_user t_ssh_port t_ssh_key
  t_ssh_host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_host // \"\"")")"
  t_ssh_user="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_user // \"\"")")"
  t_ssh_port="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_port // \"\"")")"
  t_ssh_key="$(_resolve_env_refs  "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_key // \"\"")")"

  [[ -n "${t_ssh_host}" && "${t_ssh_host}" != "null" ]] && CTRL_META_SSH_HOST="${t_ssh_host}"
  [[ -n "${t_ssh_user}" && "${t_ssh_user}" != "null" ]] && CTRL_META_SSH_USER="${t_ssh_user}"
  # shellcheck disable=SC2034
  [[ -n "${t_ssh_port}" && "${t_ssh_port}" != "null" ]] && CTRL_META_SSH_PORT="${t_ssh_port}"
  # shellcheck disable=SC2034
  [[ -n "${t_ssh_key}"  && "${t_ssh_key}"  != "null" ]] && CTRL_META_SSH_KEY="${t_ssh_key}"

  local t_compose t_cwd
  t_compose="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .compose_path // \"\"")")"
  t_cwd="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .cwd // \"\"")")"
  if [[ -n "${t_compose}" && "${t_compose}" != "null" ]]; then
    # shellcheck disable=SC2034
    CTRL_META_COMPOSE_PATH="${t_compose}"
    CTRL_META_REMOTE_DIR="$(dirname "${t_compose}")"
  fi
  local t_remote_dir
  t_remote_dir="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .remote_dir // \"\"")")"
  # shellcheck disable=SC2034
  [[ -n "${t_remote_dir}" && "${t_remote_dir}" != "null" ]] && CTRL_META_REMOTE_DIR="${t_remote_dir}"

  if [[ -n "${t_cwd}" && "${t_cwd}" != "null" ]]; then
    CTRL_META_SSH_CWD="${t_cwd}"
  elif [[ -z "${CTRL_META_SSH_CWD}" && -n "${t_compose}" && "${t_compose}" != "null" ]]; then
    CTRL_META_SSH_CWD="${CTRL_META_REMOTE_DIR}"
  fi

  CTRL_DEPLOY_SYNC_PATHS=()
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "null" ]] && continue
    CTRL_DEPLOY_SYNC_PATHS+=("${p}")
  done < <(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .sync.paths[]? // \"\"")

  msg_verbose "Deployment target: ${CTRL_DEPLOY_NAME} → ${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}:${CTRL_META_REMOTE_DIR}"
}

is_deployment_target() {
  local candidate="${1:-}"
  [[ -z "${candidate}" ]] && return 1
  local found; found="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${candidate}\") | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]]
}

# ── SSH target resolution (for ssh/rs/rl/env) ────────────────────────────────
# Accepts a deployment name OR machine name, resolves SSH vars.
# Falls back to machines.default if empty.

resolve_ssh_target() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    resolve_machine ""
    return
  fi
  if is_deployment_target "${name}"; then
    resolve_deployment "${name}"
  elif is_machine "${name}"; then
    resolve_machine "${name}"
  else
    fail "Unknown machine or deployment: '${name}'"
  fi
}

# ── service helpers ───────────────────────────────────────────────────────────

_svc_compose_service() {
  local svc="$1"
  local cs; cs="$(ctrl_service_field "${svc}" '.deploy.compose_service // ""')"
  [[ -n "${cs}" && "${cs}" != "null" ]] && printf '%s' "${cs}" || printf '%s' "${svc}"
}

_svc_compose_deps() {
  local svc="$1"
  echo "${CTRL_YAML}" | yq ".services[] | select(.name == \"${svc}\") | .deploy.depends_on[]? // \"\"" 2>/dev/null || true
}

_remote_export_block() {
  local svc
  local -a exports=()
  for svc in "$@"; do
    local img; img="$(ctrl_service_field "${svc}" '.image // ""')"
    local tag; tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
    [[ -z "${img}" || "${img}" == "null" ]] && continue
    local upper_name; upper_name="$(tr '[:lower:]-' '[:upper:]_' <<< "${svc}")"
    exports+=("export ${upper_name}_IMAGE=$(printf '%q' "${img}") ${upper_name}_TAG=$(printf '%q' "${tag}")")
  done
  [[ "${#exports[@]}" -gt 0 ]] && printf '%s; ' "${exports[@]}" || true
}

_remote_compose_services() {
  local svc
  local -a out=()
  for svc in "$@"; do out+=("$(_svc_compose_service "${svc}")"); done
  printf '%s ' "${out[@]}"
}

_remote_dep_services() {
  local svc dep
  local -a out=()
  for svc in "$@"; do
    while IFS= read -r dep; do
      [[ -z "${dep}" || "${dep}" == "null" ]] && continue
      out+=("${dep}")
    done < <(_svc_compose_deps "${svc}")
  done
  [[ "${#out[@]}" -gt 0 ]] && printf '%s ' "${out[@]}" || true
}

# ── deploy ────────────────────────────────────────────────────────────────────

deploy_services() {
  local -a svcs=("$@")
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  local exports; exports="$(_remote_export_block "${svcs[@]}")"; exports="${exports%'; '}"
  local compose_svcs; compose_svcs="$(_remote_compose_services "${svcs[@]}" | sed 's/ $//')"
  local dep_svcs; dep_svcs="$(_remote_dep_services "${svcs[@]}" | sed 's/ $//')"

  [[ -n "${compose_svcs// }" ]] || fail "No compose services resolved for: ${svcs[*]}"

  local cmd
  cmd="cd $(printf '%q' "${remote_dir}")"
  [[ -n "${exports}" ]] && cmd+=" && ${exports}"
  [[ -n "${dep_svcs// }" ]] && cmd+=" && docker compose up -d ${dep_svcs}"
  cmd+=" && docker compose pull ${compose_svcs} && docker compose up -d --no-deps --force-recreate ${compose_svcs}"

  msg "[${CTRL_DEPLOY_NAME}] Deploying: ${compose_svcs}"
  ctrl_ssh_run "${cmd}"
  msg_ok "[${CTRL_DEPLOY_NAME}] Deploy finished"
}

# ── sync ──────────────────────────────────────────────────────────────────────

sync_files() {
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"
  local sync_base
  sync_base="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${CTRL_DEPLOY_NAME}\") | .sync.base // \"\"")"
  [[ -n "${sync_base}" ]] && base="${base}/${sync_base}"

  if [[ "${#CTRL_DEPLOY_SYNC_PATHS[@]}" -eq 0 ]]; then
    msg_warn "[${CTRL_DEPLOY_NAME}] No sync.paths defined for this target; nothing to sync"
    return 0
  fi

  msg "[${CTRL_DEPLOY_NAME}] Syncing → ${CTRL_META_SSH_HOST}:${remote_dir}"
  ctrl_ssh_run "mkdir -p $(printf '%q' "${remote_dir}")"
  local p abs_p remote_parent remote_target
  for p in "${CTRL_DEPLOY_SYNC_PATHS[@]}"; do
    abs_p="${base}/${p}"
    [[ -e "${abs_p}" ]] || { msg_warn "Sync path not found, skipping: ${abs_p}"; continue; }
    remote_target="${remote_dir}/${p}"
    remote_parent="$(dirname "${remote_target}")"
    ctrl_ssh_run "mkdir -p $(printf '%q' "${remote_parent}")"
    ctrl_scp_send "${abs_p}" "${remote_parent}/"
  done
  msg_ok "[${CTRL_DEPLOY_NAME}] Sync complete"
}

# ── drift detection ───────────────────────────────────────────────────────────
# Compares declared image:tag in ctrl.yaml against running containers on the
# deployment target. Requires docker compose images --format json on the remote.

diff_deployment() {
  require_cmd jq
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  msg "[${CTRL_DEPLOY_NAME}] Checking drift on ${CTRL_META_SSH_HOST}:${remote_dir}"

  local raw_json
  raw_json="$(ctrl_ssh_run "cd $(printf '%q' "${remote_dir}") && docker compose images --format json 2>/dev/null || echo '[]'")"

  if [[ "${CTRL_JSON}" == "1" ]]; then
    local -a rows=()
    while IFS= read -r svc; do
      local kind; kind="$(ctrl_service_kind "${svc}")"
      [[ "${kind}" == "library" ]] && continue
      local declared_img; declared_img="$(ctrl_service_field "${svc}" '.image // ""')"
      local declared_tag; declared_tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
      local compose_svc; compose_svc="$(_svc_compose_service "${svc}")"
      local running_tag; running_tag="$(echo "${raw_json}" | jq -r ".[] | select(.Service == \"${compose_svc}\") | .Tag // \"\"" 2>/dev/null || echo "")"
      local status
      if [[ -z "${running_tag}" ]]; then
        status="not_running"
      elif [[ "${running_tag}" == "${declared_tag}" ]]; then
        status="ok"
      else
        status="drift"
      fi
      rows+=("{\"service\":\"${svc}\",\"declared\":\"${declared_img}:${declared_tag}\",\"running\":\"${running_tag:-none}\",\"status\":\"${status}\"}")
    done < <(ctrl_service_names)
    printf '[%s]\n' "$(IFS=,; echo "${rows[*]}")"
    return
  fi

  printf '%s%-20s %-40s %-40s %s%s\n' "${BOLD}" "SERVICE" "DECLARED" "RUNNING" "STATUS" "${RESET}"
  while IFS= read -r svc; do
    local kind; kind="$(ctrl_service_kind "${svc}")"
    [[ "${kind}" == "library" ]] && continue
    local declared_img; declared_img="$(ctrl_service_field "${svc}" '.image // ""')"
    local declared_tag; declared_tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
    local compose_svc; compose_svc="$(_svc_compose_service "${svc}")"
    local running_tag; running_tag="$(echo "${raw_json}" | jq -r ".[] | select(.Service == \"${compose_svc}\") | .Tag // \"\"" 2>/dev/null || echo "")"
    local status_label color
    if [[ -z "${running_tag}" ]]; then
      status_label="NOT RUNNING"; color="${YELLOW}"
    elif [[ "${running_tag}" == "${declared_tag}" ]]; then
      status_label="ok"; color="${GREEN}"
    else
      status_label="DRIFT"; color="${RED}"
    fi
    printf '  %-20s %-40s %-40s %s\n' \
      "${svc}" \
      "${declared_img}:${declared_tag}" \
      "${running_tag:-none}" \
      "${color}${status_label}${RESET}"
  done < <(ctrl_service_names)
}

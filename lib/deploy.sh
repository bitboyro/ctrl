#!/usr/bin/env bash
# deploy.sh — deployment target resolution, sync, deploy

# ── deployment target resolution ──────────────────────────────────────────────
# Reads deployments: from ctrl.yaml and sets CTRL_DEPLOY_* vars for the target.
# After calling resolve_deployment, CTRL_META_* SSH vars are overridden with
# the target's values so that ctrl_ssh_run / ctrl_scp_send use them.

CTRL_DEPLOY_NAME=""
CTRL_DEPLOY_SYNC_PATHS=()

resolve_deployment() {
  local target_name="${1:-}"

  # Find default name if not specified
  if [[ -z "${target_name}" ]]; then
    target_name="$(echo "${CTRL_YAML}" | yq '.deployments.default // ""')"
    [[ -n "${target_name}" && "${target_name}" != "null" ]] || \
      fail "No deployment target specified and no deployments.default set in ctrl.yaml"
  fi

  # Check the target exists
  local found; found="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]] || \
    fail "Deployment target '${target_name}' not found in ctrl.yaml deployments.targets"

  CTRL_DEPLOY_NAME="${target_name}"

  # Override SSH meta with target-specific values (falls back to meta defaults)
  local t_ssh_host; t_ssh_host="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_host // \"\"")")"
  local t_ssh_user; t_ssh_user="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_user // \"\"")")"
  local t_ssh_port; t_ssh_port="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_port // \"\"")")"
  local t_ssh_key;  t_ssh_key="$(_resolve_env_refs  "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .ssh_key // \"\"")")"
  local t_compose;  t_compose="$(_resolve_env_refs  "$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .compose_path // \"\"")")"

  [[ -n "${t_ssh_host}"  && "${t_ssh_host}"  != "null" ]] && CTRL_META_SSH_HOST="${t_ssh_host}"
  [[ -n "${t_ssh_user}"  && "${t_ssh_user}"  != "null" ]] && CTRL_META_SSH_USER="${t_ssh_user}"
  [[ -n "${t_ssh_port}"  && "${t_ssh_port}"  != "null" ]] && CTRL_META_SSH_PORT="${t_ssh_port}"
  [[ -n "${t_ssh_key}"   && "${t_ssh_key}"   != "null" ]] && CTRL_META_SSH_KEY="${t_ssh_key}"
  [[ -n "${t_compose}"   && "${t_compose}"   != "null" ]] && { CTRL_META_COMPOSE_PATH="${t_compose}"; CTRL_META_REMOTE_DIR="$(dirname "${t_compose}")"; }

  # Load sync paths for this target
  CTRL_DEPLOY_SYNC_PATHS=()
  while IFS= read -r p; do
    [[ -z "${p}" || "${p}" == "null" ]] && continue
    CTRL_DEPLOY_SYNC_PATHS+=("${p}")
  done < <(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${target_name}\") | .sync.paths[]? // \"\"")

  msg_verbose "Deployment target: ${CTRL_DEPLOY_NAME} → ${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}:${CTRL_META_REMOTE_DIR}"
}

# Returns 0 if $1 is a known deployment target name, 1 otherwise
is_deployment_target() {
  local candidate="${1:-}"
  [[ -z "${candidate}" ]] && return 1
  local found; found="$(echo "${CTRL_YAML}" | yq ".deployments.targets[] | select(.name == \"${candidate}\") | .name" 2>/dev/null || true)"
  [[ -n "${found}" && "${found}" != "null" ]]
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
    local upper_name; upper_name="${svc^^}"; upper_name="${upper_name//-/_}"
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
  local exports; exports="$(_remote_export_block "${svcs[@]}")"
  local compose_svcs; compose_svcs="$(_remote_compose_services "${svcs[@]}" | sed 's/ $//')"
  local dep_svcs; dep_svcs="$(_remote_dep_services "${svcs[@]}" | sed 's/ $//')"

  [[ -n "${compose_svcs// }" ]] || fail "No compose services resolved for: ${svcs[*]}"

  local cmd="cd $(printf '%q' "${remote_dir}")"
  [[ -n "${exports}" ]] && cmd+=" && ${exports}"
  [[ -n "${dep_svcs// }" ]] && cmd+="docker compose up -d ${dep_svcs} && "
  cmd+="docker compose pull ${compose_svcs} && docker compose up -d --no-deps --force-recreate ${compose_svcs}"

  msg "[$CTRL_DEPLOY_NAME] Deploying: ${compose_svcs}"
  ctrl_ssh_run "${cmd}"
  msg_ok "[$CTRL_DEPLOY_NAME] Deploy finished"
}

# ── sync ──────────────────────────────────────────────────────────────────────

sync_files() {
  local remote_dir="${CTRL_META_REMOTE_DIR}"
  local base; base="$(dirname "${CTRL_CONFIG_FILE}")"

  if [[ "${#CTRL_DEPLOY_SYNC_PATHS[@]}" -eq 0 ]]; then
    msg_warn "[$CTRL_DEPLOY_NAME] No sync.paths defined for this target; nothing to sync"
    return 0
  fi

  msg "[$CTRL_DEPLOY_NAME] Syncing → ${CTRL_META_SSH_HOST}:${remote_dir}"
  ctrl_ssh_run "mkdir -p $(printf '%q' "${remote_dir}")"
  local p abs_p
  for p in "${CTRL_DEPLOY_SYNC_PATHS[@]}"; do
    abs_p="${base}/${p}"
    [[ -e "${abs_p}" ]] || { msg_warn "Sync path not found, skipping: ${abs_p}"; continue; }
    ctrl_scp_send "${abs_p}" "${remote_dir}/"
  done
  msg_ok "[$CTRL_DEPLOY_NAME] Sync complete"
}

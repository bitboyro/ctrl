# ── ctrl cp ──────────────────────────────────────────────────────────────────
# Flexible file/folder copy between local and any named machine in ctrl.yaml.
# Always uses rsync for consistent semantics (progress, exclude, delete, resume).
#
# Usage: ctrl cp [--exclude PAT]... [--delete] [--progress|-P] <src> <dst>
#
# Endpoint format:
#   local:   ./path/to/file  or  path/to/file
#   remote:  machine-name:path
#
# Transfer modes:
#   local  → local   rsync -a src dst
#   local  → remote  rsync -a -e "ssh ..." src user@host:dst
#   remote → local   rsync -a -e "ssh ..." user@host:src dst
#   remote → remote  pull to mktemp, push to dst, clean up

# Parse "machine:path" or "path" into caller-set variables.
# Sets _CP_MACHINE (empty if local) and _CP_PATH.
_cp_parse_endpoint() {
  local raw="$1"
  # Check if prefix before ':' is a known machine name (not a drive letter like C:)
  local prefix="${raw%%:*}"
  local suffix="${raw#*:}"
  if [[ "${raw}" == *":"* && "${prefix}" != "${raw}" ]] && \
     yq e ".machines.hosts[] | select(.name == \"${prefix}\") | .name" "${CTRL_CONFIG_FILE}" 2>/dev/null | grep -q .; then
    _CP_MACHINE="${prefix}"
    _CP_PATH="${suffix}"
  else
    _CP_MACHINE=""
    _CP_PATH="${raw}"
  fi
}

# Build the rsync -e "ssh ..." rsh string for the current resolved machine.
# Echoes a quoted string suitable for: rsync -e "$(_cp_rsh_string)"
_cp_rsh_string() {
  local args="ssh -p ${CTRL_META_SSH_PORT} -o StrictHostKeyChecking=accept-new"
  [[ -n "${CTRL_META_SSH_KEY:-}" ]] && args="${args} -i ${CTRL_META_SSH_KEY}"
  echo "${args}"
}

# rsync wrapper that honours CTRL_DRY_RUN and sshpass.
_cp_rsync() {
  local rsh="${1}"; shift  # empty string for local→local
  local -a cmd=(rsync)
  cmd+=("${CP_RSYNC_FLAGS[@]}")
  [[ -n "${rsh}" ]] && cmd+=(-e "${rsh}")
  cmd+=("$@")

  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} ${cmd[*]}"
    return 0
  fi

  if [[ -n "${rsh}" && -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    has_cmd "${CTRL_SSHPASS_CMD}" || fail "sshpass required for password-based auth. Install: brew install sshpass / apt-get install sshpass"
    msg_verbose "rsync (password auth) ${*}"
    RSYNC_PASSWORD="${CTRL_META_SSH_PASSWORD}" \
      "${CTRL_SSHPASS_CMD}" -p "${CTRL_META_SSH_PASSWORD}" \
      "${cmd[@]}"
  else
    msg_verbose "rsync ${*}"
    "${cmd[@]}"
  fi
}

ctrl_cp() {
  has_cmd rsync || fail "rsync is required for ctrl cp. Install: brew install rsync / apt-get install rsync"

  # ── parse flags ──────────────────────────────────────────────────────────
  CP_RSYNC_FLAGS=(-a)
  local show_progress=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --exclude)
        shift
        [[ $# -gt 0 ]] || fail "--exclude requires a pattern argument"
        CP_RSYNC_FLAGS+=(--exclude "$1")
        shift
        ;;
      --exclude=*)
        CP_RSYNC_FLAGS+=(--exclude "${1#--exclude=}")
        shift
        ;;
      --delete)
        CP_RSYNC_FLAGS+=(--delete)
        shift
        ;;
      --progress|-P)
        show_progress=1
        shift
        ;;
      --)
        shift; break
        ;;
      -*)
        fail "Unknown ctrl cp option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  [[ $# -ge 2 ]] || fail "Usage: ctrl cp [--exclude PAT] [--delete] [--progress] <src> <dst>"

  [[ "${show_progress}" == "1" ]] && CP_RSYNC_FLAGS+=(--info=progress2)

  local src_raw="$1" dst_raw="$2"

  # ── parse endpoints ───────────────────────────────────────────────────────
  local _CP_MACHINE _CP_PATH
  _cp_parse_endpoint "${src_raw}"
  local src_machine="${_CP_MACHINE}" src_path="${_CP_PATH}"

  _cp_parse_endpoint "${dst_raw}"
  local dst_machine="${_CP_MACHINE}" dst_path="${_CP_PATH}"

  # ── dispatch ──────────────────────────────────────────────────────────────
  if [[ -z "${src_machine}" && -z "${dst_machine}" ]]; then
    # local → local
    msg_verbose "cp local:${src_path} → local:${dst_path}"
    _cp_rsync "" "${src_path}" "${dst_path}"

  elif [[ -z "${src_machine}" && -n "${dst_machine}" ]]; then
    # local → remote
    resolve_machine "${dst_machine}"
    local rsh; rsh="$(_cp_rsh_string)"
    local target="${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}"
    msg_verbose "cp local:${src_path} → ${dst_machine}:${dst_path}"
    _cp_rsync "${rsh}" "${src_path}" "${target}:${dst_path}"

  elif [[ -n "${src_machine}" && -z "${dst_machine}" ]]; then
    # remote → local
    resolve_machine "${src_machine}"
    local rsh; rsh="$(_cp_rsh_string)"
    local target="${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}"
    msg_verbose "cp ${src_machine}:${src_path} → local:${dst_path}"
    _cp_rsync "${rsh}" "${target}:${src_path}" "${dst_path}"

  else
    # remote → remote (local bounce)
    msg_verbose "cp ${src_machine}:${src_path} → ${dst_machine}:${dst_path} (via local tmp)"
    local tmp_dir; tmp_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp_dir}'" EXIT

    resolve_machine "${src_machine}"
    local src_rsh; src_rsh="$(_cp_rsh_string)"
    local src_target="${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}"
    _cp_rsync "${src_rsh}" "${src_target}:${src_path}" "${tmp_dir}/"

    resolve_machine "${dst_machine}"
    local dst_rsh; dst_rsh="$(_cp_rsh_string)"
    local dst_target="${CTRL_META_SSH_USER}@${CTRL_META_SSH_HOST}"
    # Push contents of tmp_dir — adjust trailing slash to preserve structure
    local tmp_src="${tmp_dir}/"
    _cp_rsync "${dst_rsh}" "${tmp_src}" "${dst_target}:${dst_path}"

    rm -rf "${tmp_dir}"
    trap - EXIT
  fi
}

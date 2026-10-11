#!/usr/bin/env bash
# scripts.sh — the `ctrl run` engine.
#
#   ctrl run                         list every runnable script
#   ctrl run <name> [args…]          run it
#     --on <where>   local | target | a,b | @tag | all   (parallel, prefixed)
#     --check        pre-flight only (os, tools, env, sudo) on every host
#     --show         header + source (+ diff vs bundled when the project owns a copy)
#     --own          copy a bundled script into scripts/ so the project owns it
#     -n/--dry-run   print what would run; scripts declaring `@dry-run: yes` run
#                    with CTRL_DRY_RUN=1 and print their exact commands
#     --yes          skip the confirmation for @sudo scripts
#
# Resolution: ctrl.yaml scripts[] entry → scripts/<name>.sh → bundled script.
# Metadata comes from `# @key: value` header lines (first 60 lines); a ctrl.yaml
# entry overrides them. Keys: name description group tags requires env
# env-optional os remote sudo flags dry-run.

CTRL_CACHE_DIR="${CTRL_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/ctrl}"
CTRL_RUN_CHECK=0
CTRL_RUN_SHOW=0
CTRL_RUN_OWN=0
CTRL_YES="${CTRL_YES:-0}"
CTRL_RUN_ON=""

# ── bundled scripts ───────────────────────────────────────────────────────────

_bundled_dir() { printf '%s\n' "${CTRL_BUNDLED_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bundled}"; }

_bundled_embedded() { declare -f _ctrl_embedded_bundled >/dev/null 2>&1; }

ctrl_bundled_names() {
  if _bundled_embedded; then
    local n; for n in $(_ctrl_embedded_bundled); do printf '%s\n' "${n}"; done
  else
    local f b
    for f in "$(_bundled_dir)"/*.sh; do
      [[ -f "${f}" ]] || continue
      b="$(basename "${f}" .sh)"
      [[ "${b}" == _* ]] || printf '%s\n' "${b}"
    done
  fi
}

ctrl_bundled_exists() {
  ctrl_is_valid_name "$1" || return 1
  if _bundled_embedded; then
    _ctrl_embedded_bundled "$1.sh" >/dev/null 2>&1
  else
    [[ -f "$(_bundled_dir)/$1.sh" ]]
  fi
}

_bundled_raw() {
  if _bundled_embedded; then _ctrl_embedded_bundled "$1"; else cat "$(_bundled_dir)/$1"; fi
}

# Write the runnable form of a bundled script (the `# ctrl:lib` marker line is
# replaced by bundled/_lib.sh) into the cache and print its path. The result is
# self-contained: it runs locally, streams to a remote, and survives --own.
_bundled_materialize() {
  local name="$1"
  local dir="${CTRL_CACHE_DIR}/bundled/${CTRL_VERSION}"
  local out="${dir}/${name}.sh"
  mkdir -p "${dir}"
  local lib; lib="$(_bundled_raw _lib.sh | grep -v '^#!/')"
  local body; body="$(_bundled_raw "${name}.sh")"
  local content=""
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "# ctrl:lib" ]]; then
      content+="# ── ctrl bundled helpers (bundled/_lib.sh) ────────────────────────────────"$'\n'"${lib}"$'\n'"# ── end helpers ──────────────────────────────────────────────────────────────"$'\n'
    else
      content+="${line}"$'\n'
    fi
  done <<< "${body}"
  if [[ ! -f "${out}" ]] || [[ "$(cat "${out}")"$'\n' != "${content}" ]]; then
    printf '%s' "${content}" > "${out}.tmp.$$" && chmod +x "${out}.tmp.$$" && mv "${out}.tmp.$$" "${out}"
  fi
  printf '%s\n' "${out}"
}

# ── header metadata ───────────────────────────────────────────────────────────

# _script_header <file> <key>  →  value (list keys normalised to space-separated)
_script_header() {
  local v
  v="$(sed -n "1,60s/^# @$2:[[:space:]]*//p" "$1" 2>/dev/null | head -1)"
  case "$2" in requires|env|env-optional|os|tags) v="${v//,/ }" ;; esac
  # trim
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "${v}"
}

# _script_yaml <name> <yq path>  →  value from the ctrl.yaml scripts[] entry
_script_yaml() {
  local v
  v="$(echo "${CTRL_YAML}" | CTRL_Q="$1" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | $2" 2>/dev/null || true)"
  [[ "${v}" == "null" ]] && v=""
  printf '%s' "${v}"
}

_script_yaml_list() {
  local v
  # A list or a single string; [x] | flatten turns both into a flat list.
  v="$(echo "${CTRL_YAML}" | CTRL_Q="$1" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | [$2] | flatten | .[] | select(. != null)" 2>/dev/null || true)"
  [[ "${v}" == "null" ]] && v=""
  printf '%s' "${v}" | tr '\n,' '  ' | sed 's/  */ /g; s/^ //; s/ $//'
}

_script_in_yaml() { [[ -n "$(_script_yaml "$1" '.name')" ]]; }

_project_script_path() {
  [[ -n "${CTRL_CONFIG_FILE}" ]] || return 1
  local p; p="$(ctrl_project_dir)/scripts/$1.sh"
  [[ -f "${p}" ]] && printf '%s\n' "${p}"
}

# ── resolver ──────────────────────────────────────────────────────────────────
# Sets S_NAME S_KIND (yaml|project|bundled) S_PATH S_DESC S_GROUP S_TAGS S_REQ
# S_ENV S_OS S_REMOTE S_SUDO S_FLAGS S_DRYRUN S_BUNDLED (1 if a bundled script
# with this name exists).
ctrl_resolve_script() {
  local name="$1"
  ctrl_valid_name "${name}" "script name"
  S_NAME="${name}"; S_KIND=""; S_PATH=""
  S_BUNDLED=0; ctrl_bundled_exists "${name}" && S_BUNDLED=1

  local ypath=""
  if _script_in_yaml "${name}"; then
    ypath="$(_script_yaml "${name}" '.path // ""')"
  fi

  if [[ -n "${ypath}" ]]; then
    S_KIND=yaml; S_PATH="$(ctrl_project_dir)/${ypath}"
    [[ -f "${S_PATH}" ]] || fail "Script file not found: ${S_PATH}"
  elif S_PATH="$(_project_script_path "${name}")"; then
    S_KIND=project
  elif [[ "${S_BUNDLED}" == "1" ]]; then
    S_KIND=bundled; S_PATH="$(_bundled_materialize "${name}")"
  else
    fail "Script '${name}' not found in ctrl.yaml scripts:, scripts/${name}.sh, or bundled scripts. Run 'ctrl run' to list."
  fi

  _script_load_meta "${name}" "${S_PATH}"
}

# Header values, overridden by the ctrl.yaml entry when it sets them.
_script_load_meta() {
  local name="$1" file="$2" y
  S_DESC="$(_script_header "${file}" description)"
  S_GROUP="$(_script_header "${file}" group)"
  S_TAGS="$(_script_header "${file}" tags)"
  S_REQ="$(_script_header "${file}" requires)"
  S_ENV="$(_script_header "${file}" env)"
  S_ENVOPT="$(_script_header "${file}" env-optional)"
  S_OS="$(_script_header "${file}" os)"
  S_REMOTE="$(_script_header "${file}" remote)"
  S_SUDO="$(_script_header "${file}" sudo)"
  S_FLAGS="$(_script_header "${file}" flags)"
  S_DRYRUN="$(_script_header "${file}" dry-run)"
  if _script_in_yaml "${name}"; then
    y="$(_script_yaml "${name}" '.description // ""')";   [[ -n "${y}" ]] && S_DESC="${y}"
    y="$(_script_yaml "${name}" '.group // ""')";         [[ -n "${y}" ]] && S_GROUP="${y}"
    y="$(_script_yaml_list "${name}" '.tags')";           [[ -n "${y}" ]] && S_TAGS="${y}"
    y="$(_script_yaml_list "${name}" '.requires.tools')"; [[ -n "${y}" ]] && S_REQ="${y}"
    y="$(_script_yaml_list "${name}" '.requires.env')";   [[ -n "${y}" ]] && S_ENV="${y}"
    y="$(_script_yaml_list "${name}" '.os')";             [[ -n "${y}" ]] && S_OS="${y}"
    y="$(_script_yaml "${name}" '.remote // ""')";        [[ -n "${y}" ]] && S_REMOTE="${y}"
    y="$(_script_yaml "${name}" '.sudo // ""')";          [[ -n "${y}" ]] && S_SUDO="${y}"
  fi
  [[ -n "${S_REMOTE}" ]] || S_REMOTE=yes
  [[ -n "${S_SUDO}" ]]   || S_SUDO=no
  S_REMOTE="$(_bool "${S_REMOTE}")"; S_SUDO="$(_bool "${S_SUDO}")"; S_DRYRUN="$(_bool "${S_DRYRUN:-no}")"
}

_bool() { case "$1" in yes|true|1|on) echo yes ;; *) echo no ;; esac; }

# ── pre-flight ────────────────────────────────────────────────────────────────

# Local pre-flight against resolved metadata. Reports every problem, then fails.
_script_preflight_check() {
  local name="$1"
  [[ "${S_NAME:-}" == "${name}" ]] || ctrl_resolve_script "${name}"
  local failed=0 item hint

  if [[ -n "${S_OS}" && " ${S_OS} " != *" ${CTRL_OS} "* ]]; then
    msg_error "Script '${name}' supports: ${S_OS} (this machine is ${CTRL_OS})"; failed=1
  fi
  for item in ${S_REQ}; do
    if ! has_cmd "${item}"; then
      hint="$(ctrl_install_hint "${item}")"
      msg_error "Script '${name}' requires tool '${item}' (not found)${hint:+ — install: ${hint}}"; failed=1
    fi
  done
  for item in ${S_ENV}; do
    [[ -n "${!item:-}" ]] || { msg_error "Script '${name}' requires env var '${item}' (not set)"; failed=1; }
  done
  [[ "${failed}" -eq 0 ]] || fail "Pre-flight checks failed for script '${name}'"
}

# Remote pre-flight as a self-contained bash snippet prepended to the script.
# Install hints are computed on the remote from its own package manager.
_script_preamble() {
  local name="$1"
  [[ "${S_NAME:-}" == "${name}" ]] || ctrl_resolve_script "${name}"
  [[ -z "${S_OS}${S_REQ}${S_ENV}" && "${S_SUDO}" != "yes" ]] && return 0

  printf '_ctrl_pf=0\n'
  if [[ -n "${S_OS}" ]]; then
    printf '_ctrl_os="$(uname -s | tr "[:upper:]" "[:lower:]")"\n'
    printf 'case %q in *" ${_ctrl_os} "*) ;; *) echo "ctrl: script %s supports: %s (remote is ${_ctrl_os})" >&2; _ctrl_pf=1 ;; esac\n' " ${S_OS} " "${name}" "${S_OS}"
  fi
  if [[ -n "${S_REQ}" ]]; then
    printf '_ctrl_pm=none; for _m in apt-get dnf apk brew; do command -v "$_m" >/dev/null 2>&1 && { _ctrl_pm="$_m"; break; }; done\n'
    local t apt dnf apk brew
    for t in ${S_REQ}; do
      apt="$(ctrl_tool_field "${t}" '.install.apt')";  dnf="$(ctrl_tool_field "${t}" '.install.dnf')"
      apk="$(ctrl_tool_field "${t}" '.install.apk')";  brew="$(ctrl_tool_field "${t}" '.install.brew')"
      printf 'command -v %q >/dev/null 2>&1 || { echo "ctrl: remote requires %q (not found)" >&2; ' "${t}" "${t}"
      printf 'case "$_ctrl_pm" in '
      [[ -n "${apt}" ]]  && printf 'apt-get) echo "  install: sudo apt-get install -y %s" >&2 ;; ' "${apt}"
      [[ -n "${dnf}" ]]  && printf 'dnf) echo "  install: sudo dnf install -y %s" >&2 ;; ' "${dnf}"
      [[ -n "${apk}" ]]  && printf 'apk) echo "  install: apk add %s" >&2 ;; ' "${apk}"
      [[ -n "${brew}" ]] && printf 'brew) echo "  install: brew install %s" >&2 ;; ' "${brew}"
      printf '*) ;; esac; _ctrl_pf=1; }\n'
    done
  fi
  local v
  for v in ${S_ENV}; do
    printf '[ -n "${%s:-}" ] || { echo "ctrl: remote requires env var %s (not set)" >&2; _ctrl_pf=1; }\n' "${v}" "${v}"
  done
  if [[ "${S_SUDO}" == "yes" ]]; then
    printf '[ "$(id -u)" = 0 ] || sudo -n true 2>/dev/null || { echo "ctrl: script %s needs root or passwordless sudo on the remote" >&2; _ctrl_pf=1; }\n' "${name}"
  fi
  printf '[ "${_ctrl_pf}" -eq 0 ] || exit 1; unset _ctrl_pf _ctrl_os _ctrl_pm _m\n'
}

# ── environment ───────────────────────────────────────────────────────────────

_script_export_env() {
  export CTRL_PROJECT="${CTRL_META_PROJECT}"
  export CTRL_SSH_HOST="${CTRL_META_SSH_HOST}"
  export CTRL_REGISTRY="${CTRL_META_REGISTRY}"
  export CTRL_REMOTE_DIR="${CTRL_META_REMOTE_DIR}"
  export CTRL_CONFIG_FILE
  export CTRL_PROJECT_DIR; CTRL_PROJECT_DIR="$(ctrl_project_dir)"
  export CTRL_MACHINE_NAME="${CTRL_MACHINE_NAME:-}"
  export CTRL_DEPLOY_NAME="${CTRL_DEPLOY_NAME:-}"
  export CTRL_SCRIPT_NAME="${S_NAME}"
  export CTRL_BIN="${CTRL_BIN:-${CTRL_SELF_DIR:-.}/ctrl.sh}"
  # ctrl.yaml with .local/ctrl.local.yaml merged in — what ctrl itself sees
  export CTRL_CONFIG_MERGED=""
  if [[ -n "${CTRL_CONFIG_FILE}" ]]; then
    mkdir -p "${CTRL_CACHE_DIR}"
    CTRL_CONFIG_MERGED="${CTRL_CACHE_DIR}/merged.$$.yaml"
    printf '%s\n' "${CTRL_YAML}" > "${CTRL_CONFIG_MERGED}"
  fi
  export CTRL_YES CTRL_DRY_RUN CTRL_OS CTRL_ARCH CTRL_PKG
  export F33D_URL; F33D_URL="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.url // ""')")"
  export F33D_TOKEN; F33D_TOKEN="$(_resolve_env_refs "$(echo "${CTRL_YAML}" | yq '.meta.f33d.token // ""')")"
}

# Variables passed to a remote script (values quoted for the remote shell).
_script_remote_env() {
  local -a pairs=(
    "CTRL_PROJECT=${CTRL_META_PROJECT}"
    "CTRL_SSH_HOST=${CTRL_META_SSH_HOST}"
    "CTRL_REGISTRY=${CTRL_META_REGISTRY}"
    "CTRL_REMOTE_DIR=${CTRL_META_REMOTE_DIR}"
    "CTRL_MACHINE_NAME=${CTRL_MACHINE_NAME:-}"
    "CTRL_DEPLOY_NAME=${CTRL_DEPLOY_NAME:-}"
    "CTRL_SCRIPT_NAME=${S_NAME}"
    "CTRL_YES=${CTRL_YES}"
    "CTRL_REMOTE=1"
  )
  local p out="env"
  for p in "${pairs[@]}"; do out+=" ${p%%=*}=$(printf '%q' "${p#*=}")"; done
  printf '%s' "${out}"
}

# ── runners ───────────────────────────────────────────────────────────────────

_run_hooks() {
  local name="$1" phase="$2" hook
  _script_in_yaml "${name}" || return 0
  while IFS= read -r hook; do
    [[ -z "${hook}" || "${hook}" == "null" ]] && continue
    if [[ "${phase}" == "post" ]]; then
      ( run_script_local "${hook}" ) || true
    else
      ( run_script_local "${hook}" ) || return $?
    fi
  done < <(echo "${CTRL_YAML}" | CTRL_Q="${name}" yq ".scripts[] | select(.name == strenv(CTRL_Q)) | .hooks.${phase}[]? // \"\"")
}

# Run a script on this machine.
run_script_local() {
  local name="$1"; shift
  ctrl_resolve_script "${name}"
  _script_preflight_check "${name}"
  _script_export_env
  _run_hooks "${name}" pre || return $?

  local exit_code=0
  msg "Running script: ${name}" >&2
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} script ${name}: bash ${S_PATH}${*:+ $*}"
    # Scripts that declare @dry-run: yes print their own exact commands.
    if [[ "${S_DRYRUN}" == "yes" ]]; then
      bash "${S_PATH}" "$@" || exit_code=$?
    fi
  else
    bash "${S_PATH}" "$@" || exit_code=$?
  fi

  export CTRL_EXIT_CODE="${exit_code}"
  if [[ "${exit_code}" -ne 0 ]]; then export F33D_LEVEL="error"; else export F33D_LEVEL="success"; fi
  if [[ "${exit_code}" -ne 0 ]]; then export F33D_MESSAGE="ctrl ${name}: failed"; else export F33D_MESSAGE="ctrl ${name}: done"; fi
  _run_hooks "${name}" post
  [[ -n "${CTRL_CONFIG_MERGED:-}" ]] && rm -f "${CTRL_CONFIG_MERGED}"

  [[ "${exit_code}" -eq 0 ]] || return "${exit_code}"
  msg_ok "Script finished: ${name}" >&2
}

# Stream a script (pre-flight preamble + body) to the resolved SSH host.
# Nothing is left on the remote. With check_only=1 only the preamble runs.
run_script_remote() {
  local name="$1" check_only="$2"; shift 2
  ctrl_resolve_script "${name}"
  [[ "${S_REMOTE}" == "yes" ]] || fail "Script '${name}' is local-only (@remote: no)"

  local target; target="$(_ssh_target)"
  local -a flags=()
  while IFS= read -r f; do flags+=("${f}"); done < <(_ssh_flags)

  local remote_cmd; remote_cmd="$(_script_remote_env) bash -s"
  if [[ "$#" -gt 0 ]]; then
    local a; remote_cmd+=" --"
    for a in "$@"; do remote_cmd+=" $(printf '%q' "${a}")"; done
  fi

  local preamble; preamble="$(_script_preamble "${name}")"
  # @env values set locally travel on stdin (never in argv, so not in ps output)
  local forwarded="" v
  for v in ${S_ENV} ${S_ENVOPT}; do
    [[ -n "${!v:-}" ]] && forwarded+="export ${v}=$(printf '%q' "${!v}")"$'\n'
  done
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} ssh ${target}: ${remote_cmd} < ${S_PATH}"
    for v in ${S_ENV} ${S_ENVOPT}; do [[ -n "${!v:-}" ]] && echo "${DIM}[DRY-RUN env]${RESET} export ${v}=<redacted>"; done
    if [[ -n "${preamble}" ]]; then
      echo "${DIM}[DRY-RUN preamble]${RESET}"
      echo "${preamble}" | sed 's/^/  /'
    fi
    return 0
  fi

  _script_stream() {
    printf '%s' "${forwarded}"
    printf '%s\n' "${preamble}"
    if [[ "${check_only}" == "1" ]]; then
      printf 'echo "pre-flight ok"\n'
    else
      cat "${S_PATH}"
    fi
  }

  local exit_code=0
  if [[ -n "${CTRL_META_SSH_PASSWORD:-}" ]]; then
    _require_sshpass
    _script_stream | "${CTRL_SSHPASS_CMD}" -p "${CTRL_META_SSH_PASSWORD}" ssh "${flags[@]}" "${target}" "${remote_cmd}" || exit_code=$?
  else
    _script_stream | ssh "${flags[@]}" "${target}" "${remote_cmd}" || exit_code=$?
  fi
  return "${exit_code}"
}

# ── --on targets ──────────────────────────────────────────────────────────────

# Expand an --on value into lines of `local`, `dep:<name>` or `machine:<name>`.
_run_expand_targets() {
  local spec="$1" tok name
  local -a out=()
  IFS=',' read -r -a toks <<< "${spec}"
  for tok in "${toks[@]}"; do
    tok="${tok// /}"
    [[ -z "${tok}" ]] && continue
    case "${tok}" in
      local) out+=("local") ;;
      all)
        while IFS= read -r name; do
          [[ -n "${name}" && "${name}" != "null" ]] && out+=("machine:${name}")
        done < <(echo "${CTRL_YAML}" | yq '.machines.hosts[].name // ""' 2>/dev/null)
        ;;
      @*)
        local tag="${tok#@}"
        ctrl_valid_name "${tag}" "machine tag"
        local found=0
        while IFS= read -r name; do
          [[ -n "${name}" && "${name}" != "null" ]] && { out+=("machine:${name}"); found=1; }
        done < <(echo "${CTRL_YAML}" | CTRL_Q="${tag}" yq '.machines.hosts[] | select((.tags // []) | contains([strenv(CTRL_Q)])) | .name' 2>/dev/null)
        [[ "${found}" == "1" ]] || fail "No machines tagged '${tag}' in ctrl.yaml"
        ;;
      *)
        ctrl_valid_name "${tok}" "target"
        if is_deployment_target "${tok}"; then out+=("dep:${tok}")
        elif is_machine "${tok}"; then out+=("machine:${tok}")
        else fail "Unknown target '${tok}'. Use local, a deployment or machine name, a,b, @tag, or all."
        fi
        ;;
    esac
  done
  [[ "${#out[@]}" -gt 0 ]] || fail "--on resolved to no targets"
  printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

_target_label() { case "$1" in local) echo local ;; *) echo "${1#*:}" ;; esac; }

# Run (or check) one script on one target. Called in a subshell per target.
_run_on_target() {
  local target="$1" name="$2"; shift 2
  case "${target}" in
    local)
      if [[ "${CTRL_RUN_CHECK}" == "1" ]]; then
        ctrl_resolve_script "${name}"; _script_preflight_check "${name}"
        [[ "${S_SUDO}" == "yes" ]] && ! _local_can_sudo && msg_warn "Script '${name}' uses sudo — you will be prompted"
        echo "pre-flight ok"
      else
        with_journal "run" "${name}" run_script_local "${name}" "$@"
      fi
      ;;
    dep:*)
      resolve_deployment "${target#dep:}"
      with_journal "run" "${name}" run_script_remote "${name}" "${CTRL_RUN_CHECK}" "$@"
      ;;
    machine:*)
      resolve_machine "${target#machine:}"
      with_journal "run" "${name}" run_script_remote "${name}" "${CTRL_RUN_CHECK}" "$@"
      ;;
  esac
}

_local_can_sudo() { [[ "$(id -u)" == "0" ]] || sudo -n true 2>/dev/null; }

# Colour per host for prefixed output.
_host_colour() {
  local -a palette=($'\033[36m' $'\033[35m' $'\033[33m' $'\033[32m' $'\033[34m' $'\033[91m')
  [[ -t 1 ]] || { printf ''; return; }
  printf '%s' "${palette[$(( $1 % ${#palette[@]} ))]}"
}

# Run on several targets in parallel; lines are prefixed with the host name.
# Returns non-zero when any target fails, after printing a per-host summary.
_run_fanout() {
  local name="$1"; shift
  local -a targets=() pids=() labels=()
  while [[ "$#" -gt 0 && "$1" != "--" ]]; do targets+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift

  local width=0 t l
  for t in "${targets[@]}"; do l="$(_target_label "${t}")"; (( ${#l} > width )) && width=${#l}; done

  local i=0 tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctrl-run.XXXXXX")"
  for t in "${targets[@]}"; do
    l="$(_target_label "${t}")"
    local colour; colour="$(_host_colour "${i}")"
    (
      set +e
      _run_on_target "${t}" "${name}" "$@" < /dev/null 2>&1
      echo "$?" > "${tmp}/${i}.rc"
    ) | while IFS= read -r line || [[ -n "${line}" ]]; do
      printf '%s%-*s%s | %s\n' "${colour}" "${width}" "${l}" "${RESET}" "${line}"
    done &
    pids+=("$!"); labels+=("${l}")
    i=$(( i + 1 ))
  done

  local failed=0 rc
  for (( i=0; i<${#pids[@]}; i++ )); do wait "${pids[i]}" || true; done
  echo ""
  printf '  %s%-*s  %s%s\n' "${BOLD}" "${width}" "HOST" "RESULT" "${RESET}"
  for (( i=0; i<${#labels[@]}; i++ )); do
    rc="$(cat "${tmp}/${i}.rc" 2>/dev/null || echo 1)"
    if [[ "${rc}" == "0" ]]; then
      printf '  %-*s  %sok%s\n' "${width}" "${labels[i]}" "${GREEN}" "${RESET}"
    else
      printf '  %-*s  %sfailed (exit %s)%s\n' "${width}" "${labels[i]}" "${RED}" "${rc}" "${RESET}"
      failed=1
    fi
  done
  rm -rf "${tmp}"
  return "${failed}"
}

# ── sudo confirmation ─────────────────────────────────────────────────────────

_confirm_sudo() {
  local name="$1" where="$2"
  [[ "${S_SUDO}" == "yes" && "${CTRL_YES}" != "1" && "${CTRL_DRY_RUN}" != "1" && "${CTRL_RUN_CHECK}" != "1" ]] || return 0
  if [[ ! -t 0 ]]; then
    fail "Script '${name}' uses sudo on ${where}. Re-run with --yes to confirm (non-interactive)."
  fi
  local answer
  printf '%s' "${YELLOW}${BOLD}?${RESET} Script '${name}' changes the system with sudo on ${where}. Continue? [y/N] " >&2
  read -r answer
  [[ "${answer}" == "y" || "${answer}" == "Y" || "${answer}" == "yes" ]] || fail "Aborted"
  CTRL_YES=1
}

# ── --show / --own ────────────────────────────────────────────────────────────

_run_show() {
  local name="$1"
  ctrl_resolve_script "${name}"
  echo ""
  printf '  %s%-10s%s %s\n' "${BOLD}" "script"   "${RESET}" "${name}"
  printf '  %s%-10s%s %s\n' "${BOLD}" "source"   "${RESET}" "${S_KIND}$([[ "${S_KIND}" != bundled && "${S_BUNDLED}" == 1 ]] && echo " (overrides bundled)")"
  printf '  %s%-10s%s %s\n' "${BOLD}" "path"     "${RESET}" "${S_PATH}"
  [[ -n "${S_DESC}" ]]  && printf '  %s%-10s%s %s\n' "${BOLD}" "about"    "${RESET}" "${S_DESC}"
  [[ -n "${S_GROUP}" ]] && printf '  %s%-10s%s %s\n' "${BOLD}" "group"    "${RESET}" "${S_GROUP}"
  [[ -n "${S_TAGS}" ]]  && printf '  %s%-10s%s %s\n' "${BOLD}" "tags"     "${RESET}" "${S_TAGS}"
  printf '  %s%-10s%s %s\n' "${BOLD}" "os"       "${RESET}" "${S_OS:-any}"
  [[ -n "${S_REQ}" ]]   && printf '  %s%-10s%s %s\n' "${BOLD}" "requires" "${RESET}" "${S_REQ}"
  [[ -n "${S_ENV}" ]]   && printf '  %s%-10s%s %s\n' "${BOLD}" "env"      "${RESET}" "${S_ENV}"
  [[ -n "${S_ENVOPT}" ]] && printf '  %s%-10s%s %s (optional)\n' "${BOLD}" "env"   "${RESET}" "${S_ENVOPT}"
  printf '  %s%-10s%s %s\n' "${BOLD}" "remote"   "${RESET}" "${S_REMOTE}"
  printf '  %s%-10s%s %s\n' "${BOLD}" "sudo"     "${RESET}" "${S_SUDO}"
  [[ -n "${S_FLAGS}" ]] && printf '  %s%-10s%s %s\n' "${BOLD}" "flags"    "${RESET}" "${S_FLAGS}"
  echo ""

  if [[ "${S_KIND}" != "bundled" && "${S_BUNDLED}" == "1" ]]; then
    local bundled; bundled="$(_bundled_materialize "${name}")"
    echo "${BOLD}diff bundled → project${RESET}"
    diff -u "${bundled}" "${S_PATH}" | sed '1,2s/^/  /' || true
  else
    echo "${DIM}── ${S_PATH} ──${RESET}"
    cat "${S_PATH}"
  fi
}

_run_own() {
  local name="$1"
  ctrl_valid_name "${name}" "script name"
  ctrl_bundled_exists "${name}" || fail "'${name}' is not a bundled script — nothing to own"
  if _script_in_yaml "${name}" || _project_script_path "${name}" >/dev/null; then
    fail "The project already owns '${name}'. See the difference with: ctrl run ${name} --show"
  fi
  local dir; dir="$(ctrl_project_dir)/scripts"
  local src; src="$(_bundled_materialize "${name}")"
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "${DIM}[DRY-RUN]${RESET} own ${name}: cp ${src} ${dir}/${name}.sh"
    return 0
  fi
  mkdir -p "${dir}"
  cp "${src}" "${dir}/${name}.sh"
  chmod +x "${dir}/${name}.sh"
  msg_ok "scripts/${name}.sh is now the project's copy — edit it freely; 'ctrl run ${name}' uses it"
  [[ -n "${CTRL_CONFIG_FILE}" ]] || msg_warn "No ctrl.yaml here: project scripts are only picked up inside a ctrl project"
}

# ── listing ───────────────────────────────────────────────────────────────────

# Rows: name, source, group, tags, description, os, remote, sudo — separated by
# the ASCII unit separator (\x1f): tabs are IFS whitespace, so empty fields would collapse.
CTRL_US=$'\x1f'
_run_rows() {
  local -a seen=()
  local name path

  _row() {
    local n="$1" kind="$2" file="$3"
    local desc group tags os remote sudo
    if [[ -n "${file}" && -f "${file}" ]]; then
      _script_load_meta "${n}" "${file}"
      desc="${S_DESC}" group="${S_GROUP}" tags="${S_TAGS}" os="${S_OS}" remote="${S_REMOTE}" sudo="${S_SUDO}"
    else
      desc="$(_script_yaml "${n}" '.description // ""')"; group="$(_script_yaml "${n}" '.group // ""')"
      tags="$(_script_yaml_list "${n}" '.tags')"; os=""; remote="yes"; sudo="no"
    fi
    [[ "${kind}" != "bundled" ]] && ctrl_bundled_exists "${n}" && kind="${kind}*"
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${n}" "${kind}" "${group:-project}" "${tags}" "${desc}" "${os}" "${remote}" "${sudo}"
  }

  while IFS= read -r name; do
    [[ -z "${name}" || "${name}" == "null" ]] && continue
    path="$(_script_yaml "${name}" '.path // ""')"
    if [[ -n "${path}" ]]; then path="$(ctrl_project_dir)/${path}"
    else path="$(_project_script_path "${name}" || true)"
      [[ -z "${path}" ]] && ctrl_bundled_exists "${name}" && path="$(_bundled_materialize "${name}")"
    fi
    _row "${name}" yaml "${path}"
    seen+=("${name}")
  done < <(echo "${CTRL_YAML}" | yq '.scripts[].name // ""' 2>/dev/null || true)

  if [[ -n "${CTRL_CONFIG_FILE}" ]]; then
    local f
    for f in "$(ctrl_project_dir)"/scripts/*.sh; do
      [[ -f "${f}" ]] || continue
      name="$(basename "${f}" .sh)"
      ctrl_is_valid_name "${name}" || continue
      [[ " ${seen[*]+"${seen[*]}"} " == *" ${name} "* ]] && continue
      _row "${name}" project "${f}"
      seen+=("${name}")
    done
  fi

  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    [[ " ${seen[*]+"${seen[*]}"} " == *" ${name} "* ]] && continue
    _row "${name}" bundled "$(_bundled_materialize "${name}")"
  done < <(ctrl_bundled_names)
}

ctrl_run_list() {
  local tag="$1"
  [[ -z "${tag}" ]] || ctrl_valid_name "${tag}" "tag"
  local rows; rows="$(_run_rows)"
  if [[ -n "${tag}" ]]; then
    rows="$(printf '%s\n' "${rows}" | awk -F"${CTRL_US}" -v t="${tag}" '{ n=split($4,a," "); for(i=1;i<=n;i++) if(a[i]==t){print; break} }')"
  fi

  if [[ "${CTRL_JSON}" == "1" ]]; then
    printf '%s\n' "${rows}" | jq -R -s '[split("\n")[] | select(length > 0) | split("\u001f") |
      {name:.[0], source:(.[1] | rtrimstr("*")), overrides_bundled:(.[1] | endswith("*")), group:.[2],
       tags:(.[3] | split(" ") | map(select(length>0))), description:.[4],
       os:(.[5] | split(" ") | map(select(length>0))), remote:(.[6]=="yes"), sudo:(.[7]=="yes")}]'
    return
  fi

  printf '%s  %-18s %-9s %-8s %s%s\n' "${BOLD}" "SCRIPT" "SOURCE" "GROUP" "DESCRIPTION" "${RESET}"
  [[ -n "${rows}" ]] || return 0
  # Project scripts first, then the library in a fixed order, then anything else
  local group_order
  group_order="$( { printf '%s\n' project dev media share setup docker network system ci meta
                    printf '%s\n' "${rows}" | awk -F"${CTRL_US}" '{print $3}'; } | awk '!s[$0]++' | \
                  while IFS= read -r g; do
                    if printf '%s\n' "${rows}" | awk -F"${CTRL_US}" -v g="${g}" '$3==g{f=1} END{exit !f}'; then echo "${g}"; fi
                  done )"
  local g
  while IFS= read -r g; do
    printf '%s\n' "${rows}" | awk -F"${CTRL_US}" -v g="${g}" '$3==g' | \
      while IFS="${CTRL_US}" read -r name kind group tags desc os remote sudo; do
        local marks=""
        [[ "${sudo}" == "yes" ]] && marks+=" ${YELLOW}[sudo]${RESET}"
        [[ -n "${os}" ]] && marks+=" ${DIM}[${os}]${RESET}"
        printf '  %-18s %-9s %-8s %s%s\n' "${name}" "${kind}" "${group}" "${desc}" "${marks}"
      done
  done <<< "${group_order}"
  echo ""
  echo "${DIM}  * = project copy overriding a bundled script   ·   ctrl run <name> --show | --own | --check | --on <where>${RESET}"
}

# ── entry point ───────────────────────────────────────────────────────────────

# ctrl_run [modifiers] [<name> [args…]]
ctrl_run() {
  local name="" tag=""
  local -a args=()
  CTRL_RUN_ON=""; CTRL_RUN_CHECK=0; CTRL_RUN_SHOW=0; CTRL_RUN_OWN=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --)          shift; args+=("$@"); break ;;
      --on)        shift; [[ -n "${1:-}" ]] || fail "--on needs a value: local | <target> | a,b | @tag | all"; CTRL_RUN_ON="$1" ;;
      --on=*)      CTRL_RUN_ON="${1#--on=}" ;;
      --check)     CTRL_RUN_CHECK=1 ;;
      --show)      CTRL_RUN_SHOW=1 ;;
      --own)       CTRL_RUN_OWN=1 ;;
      -n|--dry-run) CTRL_DRY_RUN=1 ;;
      --yes|-y)    CTRL_YES=1 ;;
      --tag)       [[ -z "${name}" ]] || { args+=("$1"); shift; continue; }; shift; tag="${1:-}" ;;
      *)
        if [[ -z "${name}" ]]; then name="$1"; else args+=("$1"); fi
        ;;
    esac
    shift
  done

  if [[ -z "${name}" ]]; then
    ctrl_run_list "${tag}"
    return
  fi

  if [[ "${CTRL_RUN_OWN}" == "1" ]]; then _run_own "${name}"; return; fi
  if [[ "${CTRL_RUN_SHOW}" == "1" ]]; then _run_show "${name}"; return; fi

  ctrl_resolve_script "${name}"

  local -a targets=()
  if [[ -n "${CTRL_RUN_ON}" ]]; then
    while IFS= read -r t; do targets+=("${t}"); done < <(_run_expand_targets "${CTRL_RUN_ON}")
  else
    targets=(local)
  fi

  local where; where="$(for t in "${targets[@]}"; do _target_label "${t}"; done | paste -sd, -)"
  _confirm_sudo "${name}" "${where}"

  if [[ "${#targets[@]}" -eq 1 ]]; then
    _run_on_target "${targets[0]}" "${name}" "${args[@]+"${args[@]}"}"
  else
    _run_fanout "${name}" "${targets[@]}" -- "${args[@]+"${args[@]}"}"
  fi
}

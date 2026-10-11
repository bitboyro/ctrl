#!/usr/bin/env bash
# platform.sh — OS/arch/package-manager detection, portable helpers, and the
# tool registry (lib/tools.yaml + ctrl.yaml meta.tools[]) with install plans.

# ── detection ─────────────────────────────────────────────────────────────────
# Pre-set values win, so tests and callers can simulate another platform.
ctrl_platform_detect() {
  if [[ -z "${CTRL_OS:-}" ]]; then
    case "$(uname -s 2>/dev/null)" in
      Darwin) CTRL_OS=darwin ;;
      Linux)  CTRL_OS=linux ;;
      *)      CTRL_OS=unknown ;;
    esac
  fi
  if [[ -z "${CTRL_ARCH:-}" ]]; then
    case "$(uname -m 2>/dev/null)" in
      x86_64|amd64)  CTRL_ARCH=amd64 ;;
      arm64|aarch64) CTRL_ARCH=arm64 ;;
      *)             CTRL_ARCH="$(uname -m 2>/dev/null || echo unknown)" ;;
    esac
  fi
  if [[ -z "${CTRL_PKG:-}" ]]; then
    if [[ "${CTRL_OS}" == "darwin" ]]; then
      has_cmd brew && CTRL_PKG=brew || CTRL_PKG=none
    elif has_cmd apt-get; then CTRL_PKG=apt
    elif has_cmd dnf;     then CTRL_PKG=dnf
    elif has_cmd apk;     then CTRL_PKG=apk
    elif has_cmd brew;    then CTRL_PKG=brew
    else CTRL_PKG=none
    fi
  fi
  export CTRL_OS CTRL_ARCH CTRL_PKG
}

# ── portable helpers ──────────────────────────────────────────────────────────

# Milliseconds since the epoch. BSD date has no %N.
ctrl_now_ms() {
  if [[ "${CTRL_OS}" == "linux" ]]; then
    date +%s%3N
  elif has_cmd perl; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'
  elif has_cmd python3; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

# Canonical absolute path of an existing file (readlink -f is missing on old macOS).
ctrl_realpath() {
  local target="$1" dir base link
  while [[ -L "${target}" ]]; do
    link="$(readlink "${target}")"
    [[ "${link}" == /* ]] && target="${link}" || target="$(dirname "${target}")/${link}"
  done
  dir="$(cd "$(dirname "${target}")" && pwd -P)" || return 1
  base="$(basename "${target}")"
  printf '%s/%s\n' "${dir}" "${base}"
}

# 0 when version $1 >= version $2 (dotted numeric compare).
ctrl_version_ge() {
  local -a a=() b=()
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  local i
  for (( i=0; i<${#b[@]} || i<${#a[@]}; i++ )); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 0
}

# ── tool registry ─────────────────────────────────────────────────────────────

_ctrl_builtin_tools_yaml() {
  if declare -f _ctrl_embedded_tools_yaml >/dev/null 2>&1; then
    _ctrl_embedded_tools_yaml
  else
    cat "${CTRL_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/tools.yaml"
  fi
}

# All tools as one YAML list: built-in registry with ctrl.yaml meta.tools[]
# merged on top (same name → project entry wins). meta.tools accepts the legacy
# `description` and `install.curl` keys.
CTRL_TOOLS_YAML=""
ctrl_tools_yaml() {
  if [[ -z "${CTRL_TOOLS_YAML}" ]]; then
    local builtin project cfg="${CTRL_YAML:-}"
    [[ -n "${cfg}" ]] || cfg='{}'
    builtin="$(_ctrl_builtin_tools_yaml | yq -o=json '.tools')"
    project="$(echo "${cfg}" | yq -o=json '[.meta.tools[]? | .why = (.why // .description // "") | .install.url = (.install.url // .install.curl // null) | del(.install.curl) | del(.description)]' 2>/dev/null || echo '[]')"
    CTRL_TOOLS_YAML="$(jq -n --argjson b "${builtin}" --argjson p "${project}" \
      '($p | map(.name)) as $names | ($b | map(select(.name as $n | $names | index($n) | not))) + $p')"
  fi
  printf '%s\n' "${CTRL_TOOLS_YAML}"
}

# ctrl_tool_field <tool> <jq path>  →  value or empty
ctrl_tool_field() {
  ctrl_tools_yaml | jq -r --arg n "$1" ".[] | select(.name == \$n) | ${2} // empty" | head -1
}

ctrl_tool_known() { [[ -n "$(ctrl_tools_yaml | jq -r --arg n "$1" '.[] | select(.name == $n) | .name')" ]]; }

# Resolve how to install a tool on this platform. Sets:
#   CTRL_INSTALL_KIND  pkg | url | pip | hint | none
#   CTRL_INSTALL_TEXT  human-readable command / hint
#   CTRL_INSTALL_ARGV  argv array (pkg, pip) — url uses CTRL_INSTALL_URL/DEST
# Order: native package manager → single-binary download → pip → hint.
_ctrl_install_plan() {
  local tool="$1"
  CTRL_INSTALL_KIND=none; CTRL_INSTALL_TEXT=""; CTRL_INSTALL_ARGV=(); CTRL_INSTALL_URL=""; CTRL_INSTALL_DEST=""
  local pkg sudo=""
  [[ "$(id -u)" != "0" ]] && has_cmd sudo && sudo="sudo"

  if [[ "${CTRL_PKG}" != "none" ]]; then
    pkg="$(ctrl_tool_field "${tool}" ".install.${CTRL_PKG}")"
    if [[ -n "${pkg}" ]]; then
      case "${CTRL_PKG}" in
        brew) CTRL_INSTALL_ARGV=(brew install "${pkg}") ;;
        apt)  CTRL_INSTALL_ARGV=(${sudo:+"${sudo}"} apt-get install -y "${pkg}") ;;
        dnf)  CTRL_INSTALL_ARGV=(${sudo:+"${sudo}"} dnf install -y "${pkg}") ;;
        apk)  CTRL_INSTALL_ARGV=(${sudo:+"${sudo}"} apk add "${pkg}") ;;
      esac
      CTRL_INSTALL_KIND=pkg; CTRL_INSTALL_TEXT="${CTRL_INSTALL_ARGV[*]}"
      return 0
    fi
  fi

  local url; url="$(ctrl_tool_field "${tool}" ".install.url_${CTRL_OS}")"
  [[ -n "${url}" ]] || url="$(ctrl_tool_field "${tool}" '.install.url')"
  if [[ -n "${url}" ]]; then
    url="${url//\{os\}/${CTRL_OS}}"; url="${url//\{arch\}/${CTRL_ARCH}}"
    CTRL_INSTALL_KIND=url; CTRL_INSTALL_URL="${url}"; CTRL_INSTALL_DEST="${HOME}/.local/bin/${tool}"
    CTRL_INSTALL_TEXT="curl -fsSL ${url} -o ~/.local/bin/${tool} && chmod +x ~/.local/bin/${tool}"
    return 0
  fi

  pkg="$(ctrl_tool_field "${tool}" '.install.pip')"
  if [[ -n "${pkg}" ]] && has_cmd python3; then
    CTRL_INSTALL_ARGV=(python3 -m pip install --user "${pkg}")
    CTRL_INSTALL_KIND=pip; CTRL_INSTALL_TEXT="${CTRL_INSTALL_ARGV[*]}"
    return 0
  fi

  local hint; hint="$(ctrl_tool_field "${tool}" '.hint')"
  if [[ -n "${hint}" ]]; then
    CTRL_INSTALL_KIND=hint; CTRL_INSTALL_TEXT="${hint}"
    return 0
  fi
  return 1
}

# One-line install hint for this platform ("brew install ffmpeg"), or empty.
ctrl_install_hint() {
  _ctrl_install_plan "$1" && printf '%s\n' "${CTRL_INSTALL_TEXT}" || true
}

# Install a tool using the platform plan. No eval: argv arrays only, and
# package names must be plain tokens.
ctrl_install_tool() {
  local tool="$1"
  _ctrl_install_plan "${tool}" || { msg_warn "No install source for ${tool} on ${CTRL_OS}/${CTRL_PKG}"; return 1; }
  case "${CTRL_INSTALL_KIND}" in
    pkg|pip)
      local w
      for w in "${CTRL_INSTALL_ARGV[@]}"; do
        [[ "${w}" =~ ^[A-Za-z0-9@/._:+=-]+$ ]] || { msg_error "Refusing unsafe install word: '${w}'"; return 1; }
      done
      run_op "install ${tool}" "${CTRL_INSTALL_ARGV[@]}"
      ;;
    url)
      [[ "${CTRL_INSTALL_URL}" == https://* ]] || { msg_error "Refusing non-https download: ${CTRL_INSTALL_URL}"; return 1; }
      run_op "download ${tool}" mkdir -p "$(dirname "${CTRL_INSTALL_DEST}")"
      run_op "download ${tool}" curl -fsSL "${CTRL_INSTALL_URL}" -o "${CTRL_INSTALL_DEST}"
      run_op "chmod ${tool}" chmod +x "${CTRL_INSTALL_DEST}"
      ;;
    hint)
      msg_warn "${tool}: install manually — ${CTRL_INSTALL_TEXT}"; return 1 ;;
  esac
}

# Installed version of a tool (first dotted number in its check output), or empty.
ctrl_tool_version() {
  local check; check="$(ctrl_tool_field "$1" '.check')"
  [[ -n "${check}" ]] || return 0
  local -a argv=(); read -r -a argv <<< "${check}"
  "${argv[@]}" 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true
}

# 0 when the tool is present and satisfies `min` (if declared).
ctrl_tool_ok() {
  has_cmd "$1" || return 1
  local min; min="$(ctrl_tool_field "$1" '.min')"
  [[ -n "${min}" ]] || return 0
  local have; have="$(ctrl_tool_version "$1")"
  [[ -n "${have}" ]] && ctrl_version_ge "${have}" "${min}"
}

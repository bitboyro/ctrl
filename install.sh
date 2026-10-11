#!/usr/bin/env bash
# ctrl installer
#
#   install.sh                 latest release — single-file binary, SHA256-verified
#   install.sh v1.2.3          a specific release
#   install.sh --main          source tree from the main branch (for contributors)
#   install.sh --init          also write ctrl.yaml in the current directory
#
# Installs to ~/.local/bin/ctrl (override with CTRL_BIN_DIR) and registers the
# Claude skill (SKILL.md) when a .claude/skills directory exists.
set -euo pipefail

CTRL_REPO="${CTRL_REPO:-https://github.com/bitboyro/ctrl}"
CTRL_BIN_DIR="${CTRL_BIN_DIR:-${HOME}/.local/bin}"
CTRL_INIT="${CTRL_INIT:-0}"
tag="latest"   # latest | vX.Y.Z | main

for arg in "$@"; do
  case "${arg}" in
    --init)     CTRL_INIT=1 ;;
    --main)     tag="main" ;;
    v[0-9]*)    tag="${arg}" ;;
    [0-9]*)     tag="v${arg}" ;;
    -h|--help)  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf 'Unknown argument: %s\n' "${arg}" >&2; exit 1 ;;
  esac
done
[[ "${tag}" =~ ^(latest|main|v[0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "Invalid version: ${tag}" >&2; exit 1; }

_print() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
_ok()    { printf '\033[1;32mok\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
_fail()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || _fail "curl is required"
command -v yq   >/dev/null 2>&1 || _warn "yq is not installed — ctrl needs mikefarah yq v4 (then run: ctrl doctor)"

_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${CTRL_BIN_DIR}"
raw_ref="${tag}"

if [[ "${tag}" == "main" ]]; then
  # Source install: the whole tree, so nothing depends on a file list here
  dest="${HOME}/.local/share/ctrl/main"
  _print "Installing ctrl from main → ${dest}"
  curl -fsSL "${CTRL_REPO}/archive/refs/heads/main.tar.gz" -o "${tmp}/src.tar.gz"
  rm -rf "${dest}"; mkdir -p "${dest}"
  tar -xzf "${tmp}/src.tar.gz" -C "${dest}" --strip-components=1
  chmod +x "${dest}/ctrl.sh"
  ln -sf "${dest}/ctrl.sh" "${CTRL_BIN_DIR}/ctrl"
  skill="${dest}/SKILL.md"
else
  if [[ "${tag}" == "latest" ]]; then
    base="${CTRL_REPO}/releases/latest/download"
    raw_ref="main"
  else
    base="${CTRL_REPO}/releases/download/${tag}"
  fi
  _print "Installing ctrl ${tag} → ${CTRL_BIN_DIR}/ctrl"
  curl -fsSL "${base}/ctrl" -o "${tmp}/ctrl"
  if curl -fsSL "${base}/ctrl.sha256" -o "${tmp}/ctrl.sha256" 2>/dev/null; then
    want="$(awk '{print $1}' "${tmp}/ctrl.sha256")"
    have="$(_sha256 "${tmp}/ctrl")"
    [[ "${want}" == "${have}" ]] || _fail "Checksum mismatch (want ${want}, got ${have}) — not installed"
    _ok "SHA256 verified"
  else
    _warn "No ctrl.sha256 published for ${tag} — installed without checksum verification"
  fi
  head -1 "${tmp}/ctrl" | grep -q '^#!/usr/bin/env bash' || _fail "Downloaded file is not the ctrl script"
  chmod +x "${tmp}/ctrl"
  mv "${tmp}/ctrl" "${CTRL_BIN_DIR}/ctrl"
  skill="${tmp}/SKILL.md"
  curl -fsSL "${CTRL_REPO/github.com/raw.githubusercontent.com}/${raw_ref}/SKILL.md" -o "${skill}" 2>/dev/null || skill=""
fi
_ok "$("${CTRL_BIN_DIR}/ctrl" version) installed → ${CTRL_BIN_DIR}/ctrl"

# ── Claude skill ──────────────────────────────────────────────────────────────
if [[ -n "${skill}" && -f "${skill}" ]]; then
  for dir in "${PWD}/.claude/skills" "${HOME}/.claude/skills"; do
    if [[ -d "${dir}" ]]; then
      mkdir -p "${dir}/ctrl"
      cp "${skill}" "${dir}/ctrl/SKILL.md"
      _ok "Claude skill registered: ${dir}/ctrl/SKILL.md"
      break
    fi
  done
fi

# ── ctrl.yaml ────────────────────────────────────────────────────────────────
if [[ ! -f "${PWD}/ctrl.yaml" ]]; then
  example="${CTRL_REPO/github.com/raw.githubusercontent.com}/${raw_ref}/ctrl.yaml.example"
  if [[ "${CTRL_INIT}" == "1" ]]; then
    curl -fsSL "${example}" -o "${PWD}/ctrl.yaml" && _ok "ctrl.yaml created — edit it, then run: ctrl doctor"
  fi
fi

case ":${PATH}:" in
  *":${CTRL_BIN_DIR}:"*) ;;
  *) _warn "${CTRL_BIN_DIR} is not in PATH — add: export PATH=\"${CTRL_BIN_DIR}:\$PATH\"" ;;
esac
echo ""
echo "  Next: ctrl doctor   ·   ctrl run   ·   ctrl help"

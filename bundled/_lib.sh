#!/usr/bin/env bash
# _lib.sh — helpers inlined into every bundled script at the `# ctrl:lib` marker.
# Keep it small, POSIX-tool-only, and safe under `set -euo pipefail`: an owned
# (--own) copy carries these lines and must work without ctrl installed.

if [[ -t 2 ]]; then
  _c_b=$'\033[1m'; _c_d=$'\033[2m'; _c_r=$'\033[31m'; _c_g=$'\033[32m'; _c_y=$'\033[33m'; _c_u=$'\033[34m'; _c_0=$'\033[0m'
else
  _c_b=''; _c_d=''; _c_r=''; _c_g=''; _c_y=''; _c_u=''; _c_0=''
fi
say()  { printf '%s==>%s %s\n' "${_c_u}${_c_b}" "${_c_0}" "$*" >&2; }
ok()   { printf '%sok%s %s\n' "${_c_g}${_c_b}" "${_c_0}" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "${_c_y}${_c_b}" "${_c_0}" "$*" >&2; }
die()  { printf '%serror%s %s\n' "${_c_r}${_c_b}" "${_c_0}" "$*" >&2; exit 1; }

CTRL_DRY_RUN="${CTRL_DRY_RUN:-0}"
CTRL_YES="${CTRL_YES:-0}"

# Parse the flags every bundled script understands; leaves the rest in ARGS.
#   --dry-run / -n   print commands instead of running them
#   --yes / -y       skip confirmations
#   --help / -h      print the @description and @flags header lines
ARGS=()
common_flags() {
  ARGS=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) CTRL_DRY_RUN=1 ;;
      -y|--yes)     CTRL_YES=1 ;;
      -h|--help)    usage; exit 0 ;;
      --)           shift; ARGS+=("$@"); break ;;
      *)            ARGS+=("$1") ;;
    esac
    shift
  done
}

usage() {
  local self="${BASH_SOURCE[0]:-$0}"
  local name; name="$(sed -n 's/^# @name:[[:space:]]*//p' "${self}" 2>/dev/null | head -1)"
  printf 'ctrl run %s — %s\n' "${name:-$(basename "${self}" .sh)}" "$(sed -n 's/^# @description:[[:space:]]*//p' "${self}" | head -1)"
  local flags; flags="$(sed -n 's/^# @flags:[[:space:]]*//p' "${self}" | head -1)"
  [[ -n "${flags}" ]] && printf '\nFlags: %s\n' "${flags}"
  printf '  -n, --dry-run   print the commands instead of running them\n  -y, --yes       skip confirmations\n'
}

# Print a command, quoted exactly as it would run; execute it unless dry-run.
run() {
  local q; q="$(printf '%q ' "$@")"
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    printf '%s\n' "${q% }"
    return 0
  fi
  printf '%s+ %s%s\n' "${_c_d}" "${q% }" "${_c_0}" >&2
  "$@"
}

has()      { command -v "$1" >/dev/null 2>&1; }
need_cmd() { local c; for c in "$@"; do has "${c}" || die "'${c}' is required (ctrl doctor / ctrl run <name> --check shows how to install it)"; done; }

os()   { if [[ -n "${CTRL_OS:-}" ]]; then echo "${CTRL_OS}"; else case "$(uname -s)" in Darwin) echo darwin ;; Linux) echo linux ;; *) echo unknown ;; esac; fi; }
arch() { if [[ -n "${CTRL_ARCH:-}" ]]; then echo "${CTRL_ARCH}"; else case "$(uname -m)" in x86_64|amd64) echo amd64 ;; arm64|aarch64) echo arm64 ;; *) uname -m ;; esac; fi; }

# Linux distribution id (debian, ubuntu, fedora, alpine, …) and codename
# (bookworm, noble, …), from /etc/os-release; CTRL_DISTRO[_CODENAME] override.
distro() {
  [[ -n "${CTRL_DISTRO:-}" ]] && { echo "${CTRL_DISTRO}"; return; }
  [[ -r /etc/os-release ]] && ( . /etc/os-release && echo "${ID:-}" ) || true
}
distro_codename() {
  [[ -n "${CTRL_DISTRO_CODENAME:-}" ]] && { echo "${CTRL_DISTRO_CODENAME}"; return; }
  [[ -r /etc/os-release ]] && ( . /etc/os-release && echo "${VERSION_CODENAME:-}" ) || true
}

# Ask y/N. --yes answers yes; without a terminal the answer is no.
confirm() {
  [[ "${CTRL_YES}" == "1" || "${CTRL_DRY_RUN}" == "1" ]] && return 0
  [[ -t 0 ]] || { warn "$1 — not confirmed (no terminal; pass --yes)"; return 1; }
  local a; printf '%s?%s %s [y/N] ' "${_c_y}${_c_b}" "${_c_0}" "$1" >&2; read -r a
  [[ "${a}" == y || "${a}" == Y || "${a}" == yes ]]
}

# SUDO is "" as root, "sudo" otherwise. Use as: run ${SUDO} apt-get …
# shellcheck disable=SC2034  # not every script needs root
SUDO=""
# shellcheck disable=SC2034  # SUDO is read by the scripts that need root
need_sudo() {
  if [[ "$(id -u)" == "0" ]]; then SUDO=""
  elif has sudo; then SUDO="sudo"
  else die "needs root or sudo"
  fi
}

open_file() {
  [[ "${CTRL_DRY_RUN}" == "1" ]] && { printf 'open %q\n' "$1"; return 0; }
  if has open && [[ "$(os)" == darwin ]]; then open "$1"
  elif has xdg-open; then xdg-open "$1" >/dev/null 2>&1 &
  fi
}

# Bytes → human (1.2M).
human() { awk -v b="$1" 'BEGIN{ split("B K M G T",u," "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf (i==1?"%d%s\n":"%.1f%s\n"), b, u[i] }'; }

file_size() { if [[ "$(os)" == darwin ]]; then stat -f %z "$1"; else stat -c %s "$1"; fi; }

# Timestamped output name in the user's preferred folder: out_name <dir-kind> <ext>
out_name() {
  local kind="$1" ext="$2" dir
  case "${kind}" in
    movies) dir="${HOME}/Movies"; [[ -d "${dir}" ]] || dir="${HOME}/Videos" ;;
    pictures) dir="${HOME}/Pictures" ;;
    *) dir="${PWD}" ;;
  esac
  [[ -d "${dir}" ]] || dir="${PWD}"
  printf '%s/%s-%s.%s\n' "${dir}" "${CTRL_SCRIPT_NAME:-ctrl}" "$(date +%Y%m%d-%H%M%S)" "${ext}"
}

#!/usr/bin/env bash
# @name: install-tailscale
# @description: Install Tailscale from its signed package repo and join your tailnet
# @group: setup
# @requires: curl
# @env-optional: TS_AUTHKEY
# @os: linux darwin
# @sudo: yes
# @flags: --ssh --hostname NAME
# @dry-run: yes
#
# Debian/Ubuntu: pkgs.tailscale.com apt repo (signed keyring). Fedora/RHEL:
# the dnf repo. Alpine: apk. macOS: Homebrew. Then `tailscale up`: with
# TS_AUTHKEY set (forwarded to --on hosts over stdin) it joins unattended —
# the key is passed as a 0600 file, never on the command line; otherwise it
# prints a login URL.
#
#   TS_AUTHKEY=tskey-auth-… ctrl run install-tailscale --on @web --ssh
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
up_args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ssh)      up_args+=(--ssh) ;;
    --hostname) shift; [[ "${1:-}" =~ ^[A-Za-z0-9-]+$ ]] || die "Invalid hostname"; up_args+=(--hostname "$1") ;;
    *)          die "Unknown argument: $1" ;;
  esac
  shift
done

if ! has tailscale; then
  case "$(os)" in
    darwin)
      need_cmd brew
      run brew install tailscale
      run sudo brew services start tailscale
      ;;
    linux)
      need_sudo
      id="$(distro)"
      codename="$(distro_codename)"
      case "${id}" in
        ubuntu|debian|raspbian)
          run ${SUDO} curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${codename}.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
          run ${SUDO} curl -fsSL "https://pkgs.tailscale.com/stable/${id}/${codename}.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
          run ${SUDO} apt-get update -q
          run ${SUDO} apt-get install -y -q tailscale
          ;;
        fedora|rhel|centos|rocky|almalinux)
          repo="fedora"; [[ "${id}" != "fedora" ]] && repo="rhel/$(. /etc/os-release && echo "${VERSION_ID%%.*}")"
          if dnf --version 2>/dev/null | head -1 | grep -q '^5\.'; then
            run ${SUDO} dnf config-manager addrepo --from-repofile="https://pkgs.tailscale.com/stable/${repo}/tailscale.repo"
          else
            run ${SUDO} dnf config-manager --add-repo "https://pkgs.tailscale.com/stable/${repo}/tailscale.repo"
          fi
          run ${SUDO} dnf -y install tailscale
          ;;
        alpine)
          run ${SUDO} apk add tailscale
          run ${SUDO} rc-update add tailscale
          run ${SUDO} service tailscale start
          ;;
        *) die "Unsupported distribution '${id:-unknown}' — see https://tailscale.com/download" ;;
      esac
      has systemctl && run ${SUDO} systemctl enable --now tailscaled
      ;;
    *) die "install-tailscale supports Linux and macOS" ;;
  esac
else
  ok "Tailscale already installed: $(tailscale version 2>/dev/null | head -1)"
fi

[[ "$(os)" == linux ]] && need_sudo || SUDO="sudo"
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  keyfile="$(mktemp)"; chmod 600 "${keyfile}"; trap 'rm -f "${keyfile}"' EXIT
  [[ "${CTRL_DRY_RUN}" == "1" ]] || printf '%s' "${TS_AUTHKEY}" > "${keyfile}"
  run ${SUDO} tailscale up --auth-key="file:${keyfile}" "${up_args[@]+"${up_args[@]}"}"
else
  say "No TS_AUTHKEY — tailscale will print a login URL"
  run ${SUDO} tailscale up "${up_args[@]+"${up_args[@]}"}"
fi
[[ "${CTRL_DRY_RUN}" == "1" ]] || ok "On the tailnet as $(tailscale ip -4 2>/dev/null | head -1)"

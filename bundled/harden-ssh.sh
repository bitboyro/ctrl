#!/usr/bin/env bash
# @name: harden-ssh
# @description: Key-only SSH, no root password login, fewer auth tries — with lock-out guards
# @group: setup
# @os: linux
# @sudo: yes
# @flags: --allow-root-keys (default) | --no-root --port N
# @dry-run: yes
#
# Writes /etc/ssh/sshd_config.d/99-ctrl-hardening.conf:
#   PasswordAuthentication no, KbdInteractiveAuthentication no,
#   PermitRootLogin prohibit-password (or no with --no-root), MaxAuthTries 3,
#   X11Forwarding no. Optionally moves SSH to --port N.
# Guards: refuses unless the connecting user has an authorized key; validates
# with `sshd -t` before reloading; keeps the existing session alive.
#
#   ctrl run harden-ssh --on prod
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
root_login="prohibit-password" port=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --no-root)         root_login="no" ;;
    --allow-root-keys) root_login="prohibit-password" ;;
    --port)            shift; port="${1:-}" ;;
    *)                 die "Unknown argument: $1" ;;
  esac
  shift
done
[[ -z "${port}" || "${port}" =~ ^[0-9]+$ ]] || die "--port must be a number"
need_sudo

user="${SUDO_USER:-${USER:-$(id -un)}}"
home="$(getent passwd "${user}" 2>/dev/null | cut -d: -f6 || echo "${HOME}")"
keys="${home}/.ssh/authorized_keys"

# Lock-out guard: key auth must already work for whoever is running this
if [[ "${CTRL_DRY_RUN}" != "1" ]]; then
  ${SUDO} test -s "${keys}" || die "${keys} is empty or missing — add your key first (ssh-copy-id), or you would be locked out"
  if [[ "${root_login}" == "no" && "${user}" == "root" ]]; then
    die "--no-root while connected as root would lock you out — create a sudo user first"
  fi
  ${SUDO} grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config \
    || die "/etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf' line — add it, then re-run"
fi

conf="# Managed by ctrl run harden-ssh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin ${root_login}
MaxAuthTries 3
X11Forwarding no
${port:+Port ${port}}"

dest=/etc/ssh/sshd_config.d/99-ctrl-hardening.conf
say "Writing ${dest}"
if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  printf '%s\n' "${conf}" | sed 's/^/  /'
else
  printf '%s\n' "${conf}" | ${SUDO} tee "${dest}" >/dev/null
fi

# Validate before reload; roll back if sshd rejects it
if [[ "${CTRL_DRY_RUN}" != "1" ]] && ! ${SUDO} sshd -t; then
  ${SUDO} rm -f "${dest}"
  die "sshd -t rejected the config — reverted, nothing changed"
fi
if has systemctl; then
  run ${SUDO} systemctl reload ssh 2>/dev/null || run ${SUDO} systemctl reload sshd
else
  run ${SUDO} service ssh reload
fi

[[ -n "${port}" ]] && warn "SSH now also listens on ${port}: open it in your firewall and set machines.hosts[].port in ctrl.yaml before closing this session"
ok "SSH hardened (password login off, root: ${root_login})"

#!/usr/bin/env bash
# @name: ufw-basics
# @description: Firewall: deny incoming, allow SSH (+ ports you name) — SSH port detected
# @group: setup
# @os: linux
# @sudo: yes
# @flags: --allow 80,443 --limit-ssh
# @dry-run: yes
#
# Installs ufw if needed, allows the port sshd actually listens on (so the
# current session survives), then enables the firewall. Note: ports published
# by Docker bypass ufw (Docker writes its own iptables rules) — bind containers
# to 127.0.0.1 behind Traefik instead.
#
#   ctrl run ufw-basics --on prod --allow 80,443
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
allow="" limit=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --allow)     shift; allow="${1:-}" ;;
    --limit-ssh) limit=1 ;;
    *)           die "Unknown argument: $1" ;;
  esac
  shift
done
need_sudo

if ! has ufw; then
  if has apt-get; then run ${SUDO} apt-get install -y -q ufw
  elif has dnf; then run ${SUDO} dnf -y install ufw
  elif has apk; then run ${SUDO} apk add ufw
  else die "Install ufw first"; fi
fi

# The port this session came in on, else sshd's configured port, else 22
ssh_port="${SSH_CONNECTION:+$(awk '{print $4}' <<< "${SSH_CONNECTION}")}"
[[ -n "${ssh_port}" ]] || ssh_port="$(${SUDO} sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
ssh_port="${ssh_port:-22}"

run ${SUDO} ufw default deny incoming
run ${SUDO} ufw default allow outgoing
if [[ "${limit}" == "1" ]]; then run ${SUDO} ufw limit "${ssh_port}/tcp"
else run ${SUDO} ufw allow "${ssh_port}/tcp"; fi

IFS=',' read -r -a ports <<< "${allow}"
for p in "${ports[@]+"${ports[@]}"}"; do
  p="${p// /}"; [[ -z "${p}" ]] && continue
  [[ "${p}" =~ ^[0-9]+(/(tcp|udp))?$ ]] || die "Invalid port: ${p}"
  run ${SUDO} ufw allow "${p}"
done

run ${SUDO} ufw --force enable
[[ "${CTRL_DRY_RUN}" == "1" ]] || ${SUDO} ufw status verbose
warn "Docker-published ports bypass ufw — bind them to 127.0.0.1 or use Traefik"

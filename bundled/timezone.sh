#!/usr/bin/env bash
# @name: timezone
# @description: Show or set the system timezone — no argument infers it from your IP
# @group: setup
# @os: linux darwin
# @sudo: no
# @flags: [Area/City] --show
# @dry-run: yes
#
#   ctrl run timezone --show               # current zone and time
#   ctrl run timezone Europe/Bucharest --on @web
#   ctrl run timezone                       # detect from public IP, then set
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
zone="" show=0
for a in "$@"; do
  case "${a}" in
    --show) show=1 ;;
    -*)     die "Unknown flag: ${a}" ;;
    *)      zone="${a}" ;;
  esac
done

current() {
  if [[ "$(os)" == darwin ]]; then readlink /etc/localtime | sed 's|.*/zoneinfo/||'
  elif has timedatectl; then timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null
  else cat /etc/timezone 2>/dev/null || readlink /etc/localtime | sed 's|.*/zoneinfo/||'; fi
}

if [[ "${show}" == "1" ]]; then
  printf '%s  (%s)\n' "$(current)" "$(date '+%Y-%m-%d %H:%M %Z')"
  exit 0
fi

if [[ -z "${zone}" ]]; then
  zone="$(curl -fsS --max-time 5 https://ipapi.co/timezone 2>/dev/null || true)"
  [[ -n "${zone}" ]] || die "Could not infer a timezone — pass one, e.g. Europe/Berlin"
  say "Detected ${zone} from the public IP"
fi
[[ "${zone}" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+){0,2}$ ]] || die "Invalid timezone: ${zone}"
[[ -e "/usr/share/zoneinfo/${zone}" || "${CTRL_DRY_RUN}" == "1" ]] || die "Unknown timezone: ${zone}"
[[ "$(current)" == "${zone}" ]] && { ok "Already ${zone}"; exit 0; }

confirm "Set the timezone to ${zone} (was $(current))?" || die "Not changed"
need_sudo
if [[ "$(os)" == darwin ]]; then
  run sudo systemsetup -settimezone "${zone}"
elif has timedatectl; then
  run ${SUDO} timedatectl set-timezone "${zone}"
else
  run ${SUDO} ln -sf "/usr/share/zoneinfo/${zone}" /etc/localtime
  [[ "${CTRL_DRY_RUN}" == "1" ]] || printf '%s\n' "${zone}" | ${SUDO} tee /etc/timezone >/dev/null
fi
[[ "${CTRL_DRY_RUN}" == "1" ]] || ok "Timezone: $(current) — $(date '+%H:%M %Z')"

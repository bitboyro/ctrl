#!/usr/bin/env bash
# @name: hogs
# @description: Biggest folders, hungriest processes, fullest disks
# @group: system
# @flags: [path] --top 10 --disk | --procs
# @dry-run: yes
#
# Default path: the current folder, or / on --on hosts (one filesystem only).
#
#   ctrl run hogs                    # here
#   ctrl run hogs /var --top 5
#   ctrl run hogs --procs --on @web
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
path="" top=10 what=all
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --top)   shift; top="${1:-10}" ;;
    --disk)  what=disk ;;
    --procs) what=procs ;;
    -*)      die "Unknown flag: $1" ;;
    *)       path="$1" ;;
  esac
  shift
done
[[ "${top}" =~ ^[0-9]+$ ]] || die "--top must be a number"
[[ -n "${path}" ]] || { [[ "${CTRL_REMOTE:-0}" == "1" ]] && path=/ || path="${PWD}"; }

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  printf 'du -xk -d 1 %q | sort -rn | head -%s\n' "${path}" "$(( top + 1 ))"
  echo "ps (by %mem and %cpu) · df -h"
  exit 0
fi

if [[ "${what}" != "procs" ]]; then
  printf '%sbiggest in %s%s\n' "${_c_b}" "${path}" "${_c_0}"
  du -xk -d 1 "${path}" 2>/dev/null | sort -rn | head -n "$(( top + 1 ))" | tail -n +2 | \
    while read -r kb p; do printf '  %8s  %s\n' "$(human $(( kb * 1024 )))" "${p}"; done
  echo ""
  printf '%sdisks%s\n' "${_c_b}" "${_c_0}"
  df -h 2>/dev/null | awk 'NR==1 || ($1 ~ /^\/dev\// && $1 !~ /loop/)' | sed 's/^/  /'
  echo ""
fi

if [[ "${what}" != "disk" ]]; then
  printf '%smemory%s\n' "${_c_b}" "${_c_0}"
  if [[ "$(os)" == darwin ]]; then ps -Ao pid,%mem,%cpu,comm -m | head -n "$(( top + 1 ))" | sed 's/^/  /'
  else ps -eo pid,%mem,%cpu,comm --sort=-%mem | head -n "$(( top + 1 ))" | sed 's/^/  /'; fi
  echo ""
  printf '%scpu%s\n' "${_c_b}" "${_c_0}"
  if [[ "$(os)" == darwin ]]; then ps -Ao pid,%cpu,%mem,comm -r | head -n "$(( top + 1 ))" | sed 's/^/  /'
  else ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head -n "$(( top + 1 ))" | sed 's/^/  /'; fi
fi

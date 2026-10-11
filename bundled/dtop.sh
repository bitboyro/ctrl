#!/usr/bin/env bash
# @name: dtop
# @description: Live CPU / memory / network / IO per container, sorted by memory
# @group: docker
# @requires: docker
# @flags: --once
# @dry-run: yes
#
# Interactive terminals get a live view; --once (the default on --on hosts)
# prints one snapshot, heaviest memory user first.
#
#   ctrl run dtop
#   ctrl run dtop --on @web          # one snapshot per host, in parallel
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
once=0
[[ "${CTRL_REMOTE:-0}" == "1" || ! -t 1 ]] && once=1
for a in "$@"; do [[ "${a}" == "--once" ]] && once=1 || die "Unknown argument: ${a}"; done

fmt='table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'
if [[ "${once}" == "1" ]]; then
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then run docker stats --no-stream --format "${fmt}"; exit 0; fi
  out="$(docker stats --no-stream --format "${fmt}")"
  head -1 <<< "${out}"
  tail -n +2 <<< "${out}" | sort -t $'\t' -k4 -rn 2>/dev/null || tail -n +2 <<< "${out}"
  echo ""
  printf '%s containers · %s\n' "$(docker ps -q | wc -l | tr -d ' ')" "$(docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | paste -sd' ' -)"
else
  run docker stats --format "${fmt}"
fi

#!/usr/bin/env bash
# @name: toolbox
# @description: Interactive shell in the ctrl-tools container (curl, dig, tcpdump, psql…)
# @group: network
# @requires: docker
# @flags: [svc|network] --mount src:dst --no-network
# @remote: no
# @dry-run: yes
#
#   ctrl run toolbox                 # on the default bridge network
#   ctrl run toolbox api             # on the api service's network
#   ctrl run toolbox --mount ./logs:/data
#   On a server:  ctrl ssh prod -- -t docker run --rm -it ghcr.io/bitboyro/ctrl-tools:latest sh
set -euo pipefail
# ctrl:lib

image="${CTRL_TOOLS_IMAGE:-ghcr.io/bitboyro/ctrl-tools:latest}"
common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"

net="" mounts=() no_network=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --mount)      shift; mounts+=(-v "${1:-}") ;;
    --no-network) no_network=1 ;;
    -*)           die "Unknown flag: $1" ;;
    *)            net="$1" ;;
  esac
  shift
done

net_args=()
if [[ "${no_network}" == "1" ]]; then
  net_args=(--network none)
elif [[ -n "${net}" ]]; then
  [[ "${net}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid name: '${net}'"
  # A service/container name → its network; otherwise treat it as a network name
  c="$(docker ps --filter "label=com.docker.compose.service=${net}" --format '{{.Names}}' 2>/dev/null | head -1 || true)"
  if [[ -n "${c}" ]]; then
    net="$(docker inspect "${c}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | awk '{print $1}')"
  fi
  net_args=(--network "${net}")
fi

say "ctrl-tools shell${net:+ (network: ${net})}"
run docker run --rm -it "${net_args[@]+"${net_args[@]}"}" "${mounts[@]+"${mounts[@]}"}" "${image}" sh

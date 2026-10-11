#!/usr/bin/env bash
# @name: sniff
# @description: Live tcpdump of a service's container network (or the host)
# @group: network
# @requires: docker
# @flags: <svc|container> --filter 'port 5432' --duration S --save --host
# @remote: yes
# @dry-run: yes
#
# Runs tcpdump inside the ctrl-tools container attached to the target's Docker
# network. The target is a ctrl.yaml service (its compose_service is used), a
# compose service name, or a container name. On a remote host (--on) the name
# is matched by the compose service label. --host sniffs on the host itself.
#
#   ctrl run sniff api                          # 10 s on api's network
#   ctrl run sniff api --filter 'port 5432' --duration 30
#   ctrl run sniff api --save                   # → .local/captures/api-<ts>.pcap
#   ctrl run sniff api --on prod                # on the prod host
set -euo pipefail
# ctrl:lib

image="${CTRL_TOOLS_IMAGE:-ghcr.io/bitboyro/ctrl-tools:latest}"
common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"

target="" filter="" duration=10 save=0 host_mode=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --filter)   shift; filter="${1:-}" ;;
    --duration) shift; duration="${1:-}" ;;
    --save)     save=1 ;;
    --host)     host_mode=1 ;;
    -*)         die "Unknown flag: $1" ;;
    *)          [[ -z "${target}" ]] && target="$1" || die "Unexpected argument: $1" ;;
  esac
  shift
done
[[ -n "${target}" || "${host_mode}" == "1" ]] || die "Usage: ctrl run sniff <svc|container> [--filter EXPR] [--duration S] [--save] [--host]"
[[ -z "${target}" || "${target}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid target name: '${target}'"
[[ "${duration}" =~ ^[0-9]+$ ]] || die "--duration must be a whole number of seconds: '${duration}'"

filter_args=()
[[ -n "${filter}" ]] && filter_args=("${filter}")

if [[ "${host_mode}" == "1" ]]; then
  need_cmd tcpdump
  need_sudo
  say "tcpdump on host (${duration}s) — filter: ${filter:-any}"
  run ${SUDO} timeout "${duration}" tcpdump -l -n "${filter_args[@]+"${filter_args[@]}"}" || true
  exit 0
fi

# ctrl.yaml service → compose service name (when the config is readable here)
cfg="${CTRL_CONFIG_MERGED:-${CTRL_CONFIG_FILE:-}}"
compose="${target}"
if [[ -n "${cfg}" && -f "${cfg}" ]] && has yq; then
  cs="$(CTRL_Q="${target}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .deploy.compose_service // ""' "${cfg}" 2>/dev/null || true)"
  [[ -n "${cs}" && "${cs}" != "null" ]] && compose="${cs}"
fi

# Find the container: compose label first, then a container of that name
container=""
if [[ "${CTRL_DRY_RUN}" != "1" ]]; then
  container="$(docker ps --filter "label=com.docker.compose.service=${compose}" --format '{{.Names}}' | head -1)"
  [[ -n "${container}" ]] || container="$(docker ps --filter "name=^${compose}$" --format '{{.Names}}' | head -1)"
  [[ -n "${container}" ]] || die "No running container for '${compose}'"
else
  container="${compose}"
fi
network="$(docker inspect "${container}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | awk '{print $1}' || true)"
[[ -n "${network}" ]] || network="container:${container}"

mount_args=() out_arg=()
if [[ "${save}" == "1" ]]; then
  outdir="${CTRL_PROJECT_DIR:-${PWD}}/.local/captures"
  ts="$(date +%Y%m%d-%H%M%S)"
  [[ "${CTRL_DRY_RUN}" == "1" ]] || mkdir -p "${outdir}"
  mount_args=(-v "${outdir}:/capture")
  out_arg=(-w "/capture/${target:-host}-${ts}.pcap")
  say "Saving capture to ${outdir}/${target:-host}-${ts}.pcap"
fi

say "Sniffing ${container} (network: ${network}, ${duration}s)"
run docker run --rm --cap-add NET_ADMIN --cap-add NET_RAW \
  --network "${network}" "${mount_args[@]+"${mount_args[@]}"}" \
  "${image}" timeout "${duration}" tcpdump -l -n "${out_arg[@]+"${out_arg[@]}"}" "${filter_args[@]+"${filter_args[@]}"}" || true

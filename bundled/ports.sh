#!/usr/bin/env bash
# @name: ports
# @description: What is listening on which port, and which process owns it
# @group: network
# @os: linux darwin
# @flags: [port] --udp --kill PORT
# @dry-run: yes
#
# Linux: ss. macOS: lsof. Run with sudo to see other users' processes.
# --kill PORT asks, then stops the process holding that port.
#
#   ctrl run ports
#   ctrl run ports 8080
#   ctrl run ports --on all          # every machine, prefixed
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
port="" udp=0 kill_port=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --udp)  udp=1 ;;
    --kill) shift; kill_port="${1:-}" ;;
    -*)     die "Unknown flag: $1" ;;
    *)      port="$1" ;;
  esac
  shift
done
[[ -z "${port}${kill_port}" || "${port}${kill_port}" =~ ^[0-9]+$ ]] || die "Port must be a number"

# Normalised rows: PROTO ADDRESS PORT PID PROCESS
listening() {
  if [[ "$(os)" == darwin ]]; then
    local sel=(-iTCP -sTCP:LISTEN); [[ "${udp}" == "1" ]] && sel=(-iUDP)
    lsof -nP "${sel[@]}" 2>/dev/null | awk 'NR>1 {
      addr=$9; p=addr; sub(/.*:/,"",p); a=addr; sub(/:[^:]*$/,"",a)
      proto=($8=="UDP")?"udp":"tcp"; print proto, a, p, $2, $1 }' | sort -u -k3,3n
  else
    local f=-tlnpH; [[ "${udp}" == "1" ]] && f=-ulnpH
    ss "${f}" 2>/dev/null | awk '{
      proto=($1 ~ /udp/ || $1=="UNCONN")?"udp":"tcp"; local_=$4; p=local_; sub(/.*:/,"",p); a=local_; sub(/:[^:]*$/,"",a)
      pid="-"; name="-"; if (match($0, /pid=[0-9]+/)) pid=substr($0, RSTART+4, RLENGTH-4)
      if (match($0, /\("[^"]+"/)) name=substr($0, RSTART+2, RLENGTH-3)
      print proto, a, p, pid, name }' | sort -u -k3,3n
  fi
}

if [[ -n "${kill_port}" ]]; then
  pid="$(listening | awk -v p="${kill_port}" '$3==p {print $4; exit}')"
  [[ -n "${pid}" && "${pid}" != "-" ]] || die "Nothing (visible) is listening on ${kill_port}"
  proc="$(ps -p "${pid}" -o comm= 2>/dev/null || echo "?")"
  confirm "Stop ${proc} (pid ${pid}) listening on ${kill_port}?" || exit 0
  run kill "${pid}"
  exit 0
fi

[[ "${CTRL_DRY_RUN}" == "1" ]] && { [[ "$(os)" == darwin ]] && echo "lsof -nP -iTCP -sTCP:LISTEN" || echo "ss -tlnpH"; exit 0; }

rows="$(listening)"
[[ -n "${port}" ]] && rows="$(awk -v p="${port}" '$3==p' <<< "${rows}")"
if [[ -z "${rows}" ]]; then
  warn "Nothing listening${port:+ on ${port}}"; exit 0
fi
{ printf 'PROTO\tADDRESS\tPORT\tPID\tPROCESS\n'; tr ' ' '\t' <<< "${rows}"; } | column -t -s $'\t'
[[ "$(id -u)" == "0" ]] || printf '\n%s(run as root to see every process: ctrl run ports with sudo)%s\n' "${_c_d}" "${_c_0}" >&2

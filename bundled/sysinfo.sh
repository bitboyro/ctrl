#!/usr/bin/env bash
# @name: sysinfo
# @description: One-screen machine summary — OS, CPU, memory, disk, load, docker, IPs
# @group: system
# @flags: --short
# @dry-run: yes
#
# Pure read-only; works on macOS and any Linux. Made for fan-out:
#
#   ctrl run sysinfo
#   ctrl run sysinfo --on all --short     # one line per machine
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
short=0
for a in "$@"; do [[ "${a}" == "--short" ]] && short=1 || die "Unknown argument: ${a}"; done
[[ "${CTRL_DRY_RUN}" == "1" ]] && { echo "read-only: uname, /proc or sysctl, df, docker ps"; exit 0; }

o="$(os)"
host="$(hostname -s 2>/dev/null || hostname)"
if [[ "${o}" == darwin ]]; then
  osname="macOS $(sw_vers -productVersion 2>/dev/null)"
  cpu="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"; cores="$(sysctl -n hw.ncpu)"
  mem_total=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  pagesize="$(sysctl -n hw.pagesize)"
  mem_used=$(( ( $(vm_stat | awk '/Pages active|Pages wired|Pages occupied by compressor/ {gsub("\\.","",$NF); s+=$NF} END{print s}') * pagesize ) / 1024 / 1024 ))
  up="$(uptime | sed 's/.*up \([^,]*\),.*/\1/')"
  load="$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')"
else
  # shellcheck disable=SC1091
  osname="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -s)"
  cpu="$(awk -F: '/model name|Model/ {print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"; cores="$(nproc 2>/dev/null || echo ?)"
  mem_total=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  mem_used=$(( mem_total - $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
  up="$(uptime -p 2>/dev/null | sed 's/^up //' || uptime)"
  load="$(cut -d' ' -f1-3 /proc/loadavg)"
fi
kernel="$(uname -r)"; arch_="$(uname -m)"
disk="$(df -h / | awk 'NR==2{print $3 " / " $2 " (" $5 ")"}')"
mem_pct=$(( mem_used * 100 / (mem_total > 0 ? mem_total : 1) ))
docker_line="—"
if has docker && docker info >/dev/null 2>&1; then
  docker_line="$(docker version --format '{{.Server.Version}}' 2>/dev/null) · $(docker ps -q | wc -l | tr -d ' ') running / $(docker ps -aq | wc -l | tr -d ' ') total"
fi
ip_="$( { [[ "${o}" == darwin ]] && ipconfig getifaddr en0; } 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"

bar() {  # bar <percent>
  local p="$1" w=20 f; f=$(( p * w / 100 )); (( f > w )) && f=$w
  local c="${_c_g}"; (( p >= 70 )) && c="${_c_y}"; (( p >= 90 )) && c="${_c_r}"
  printf '%s%s%s%s' "${c}" "$(printf '%*s' "${f}" '' | tr ' ' '█')" "${_c_d}$(printf '%*s' $(( w - f )) '' | tr ' ' '░')" "${_c_0}"
}

if [[ "${short}" == "1" ]]; then
  printf '%-14s %-28s %2s cpu  load %-14s mem %3d%%  disk %s  docker %s\n' "${host}" "${osname:0:28}" "${cores}" "${load}" "${mem_pct}" "$(df -h / | awk 'NR==2{print $5}')" "${docker_line%% ·*}"
  exit 0
fi

logo_mac=( "    .:'  " "  __ :'__ " ".'  \`'  \`." ":        :" ":        :" " \`.____.' " )
logo_lin=( "   .--.   " "  |o_o |  " "  |:_/ |  " " //   \\ \\ " "(|     | )" "/'\\_  _/\`\\" )
if [[ "${o}" == darwin ]]; then logo=("${logo_mac[@]}"); else logo=("${logo_lin[@]}"); fi

lines=(
  "${_c_b}${host}${_c_0}  ${_c_d}${ip_:-}${_c_0}"
  "${_c_u}os${_c_0}      ${osname} · ${kernel} · ${arch_}"
  "${_c_u}cpu${_c_0}     ${cpu:-?} (${cores} cores) · load ${load}"
  "${_c_u}memory${_c_0}  $(bar "${mem_pct}") ${mem_used} / ${mem_total} MB (${mem_pct}%)"
  "${_c_u}disk /${_c_0}  ${disk}"
  "${_c_u}uptime${_c_0}  ${up}"
  "${_c_u}docker${_c_0}  ${docker_line}"
)
for i in "${!lines[@]}"; do
  printf '%s%s%s  %s\n' "${_c_u}" "${logo[i]:-          }" "${_c_0}" "${lines[i]}"
done

#!/usr/bin/env bash
# @name: myip
# @description: Local and public IP, with location and network owner
# @group: network
# @requires: curl
# @flags: --public --no-geo --json
# @dry-run: yes
#
#   ctrl run myip
#   ctrl run myip --on all            # every server's public address at once
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
public_only=0 geo=1 json=0
for a in "$@"; do
  case "${a}" in
    --public) public_only=1 ;;
    --no-geo) geo=0 ;;
    --json)   json=1 ;;
    *)        die "Unknown argument: ${a}" ;;
  esac
done

local_ips() {
  if [[ "$(os)" == darwin ]]; then
    ifconfig 2>/dev/null | awk '/^[a-z]/{i=$1; sub(":","",i)} /inet /&&$2!="127.0.0.1"{print i, $2}'
  else
    ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{split($4,a,"/"); print $2, a[1]}' \
      || hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d; s/^/- /'
  fi
}

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  echo "curl -fsS https://api.ipify.org"
  [[ "${geo}" == "1" ]] && echo "curl -fsS https://ipinfo.io/<ip>/json"
  exit 0
fi

pub="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
info="{}"
[[ "${geo}" == "1" && -n "${pub}" ]] && info="$(curl -fsS --max-time 5 "https://ipinfo.io/${pub}/json" 2>/dev/null || echo '{}')"

if [[ "${json}" == "1" ]]; then
  locals="$(local_ips | awk '{printf "%s{\"iface\":\"%s\",\"ip\":\"%s\"}", (NR>1?",":""), $1, $2}')"
  printf '{"public":"%s","local":[%s],"geo":%s}\n' "${pub}" "${locals}" "${info}"
  exit 0
fi

field() { sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" <<< "${info}" | head -1; }
printf '%spublic%s  %s' "${_c_b}" "${_c_0}" "${pub:-unavailable}"
if [[ "${geo}" == "1" && "${info}" != "{}" ]]; then
  printf '  %s%s, %s · %s%s' "${_c_d}" "$(field city)" "$(field country)" "$(field org)" "${_c_0}"
fi
echo ""
[[ "${public_only}" == "1" ]] && exit 0
local_ips | while read -r iface ip; do printf '%slocal%s   %-15s %s%s%s\n' "${_c_b}" "${_c_0}" "${ip}" "${_c_d}" "${iface}" "${_c_0}"; done

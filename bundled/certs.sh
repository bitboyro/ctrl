#!/usr/bin/env bash
# @name: certs
# @description: TLS certificate expiry, issuer and names for hosts — or every https service in ctrl.yaml
# @group: network
# @requires: openssl
# @flags: [host[:port] …] --warn 21
# @dry-run: yes
#
# With no hosts, checks the https health.url / api.base_url of every service in
# ctrl.yaml. Exit code is non-zero if any certificate expires within --warn days.
#
#   ctrl run certs example.com api.example.com:8443
#   ctrl run certs                   # every https endpoint of the project
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
warn_days=21 hosts=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --warn) shift; warn_days="${1:-21}" ;;
    -*)     die "Unknown flag: $1" ;;
    *)      hosts+=("$1") ;;
  esac
  shift
done
[[ "${warn_days}" =~ ^[0-9]+$ ]] || die "--warn must be days"

if [[ "${#hosts[@]}" -eq 0 ]]; then
  cfg="${CTRL_CONFIG_MERGED:-${CTRL_CONFIG_FILE:-}}"
  [[ -n "${cfg}" && -f "${cfg}" ]] && has yq || die "Usage: ctrl run certs <host[:port]> …  (or run inside a ctrl project)"
  while IFS= read -r u; do
    [[ "${u}" == https://* ]] || continue
    h="${u#https://}"; h="${h%%/*}"; hosts+=("${h}")
  done < <(yq '.services[] | (.health.url // ""), (.api.base_url // "")' "${cfg}" | sort -u)
  [[ "${#hosts[@]}" -gt 0 ]] || die "No https endpoints in ctrl.yaml — pass hosts explicitly"
fi

epoch() {  # openssl date → epoch seconds (GNU and BSD date)
  date -d "$1" +%s 2>/dev/null || date -j -f "%b %e %T %Y %Z" "$1" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$1" +%s
}

bad=0 now="$(date +%s)"
for hp in "${hosts[@]}"; do
  host="${hp%%:*}"; port="443"; [[ "${hp}" == *:* ]] && port="${hp##*:}"
  [[ "${host}" =~ ^[A-Za-z0-9.-]+$ && "${port}" =~ ^[0-9]+$ ]] || die "Invalid host: ${hp}"
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    printf 'openssl s_client -connect %s:%s -servername %s </dev/null | openssl x509 -noout -enddate -issuer -ext subjectAltName\n' "${host}" "${port}" "${host}"
    continue
  fi
  pem="$(openssl s_client -connect "${host}:${port}" -servername "${host}" </dev/null 2>/dev/null | openssl x509 2>/dev/null || true)"
  if [[ -z "${pem}" ]]; then
    printf '%s✗%s %-32s no certificate (unreachable or not TLS)\n' "${_c_r}" "${_c_0}" "${hp}"; bad=1; continue
  fi
  end="$(openssl x509 -noout -enddate <<< "${pem}" | cut -d= -f2)"
  issuer="$(openssl x509 -noout -issuer <<< "${pem}" | sed -n 's/.*O *= *\([^,/]*\).*/\1/p')"
  sans="$(openssl x509 -noout -ext subjectAltName <<< "${pem}" 2>/dev/null | tail -n +2 | tr -d ' ' | sed 's/DNS://g' | cut -c1-60)"
  days=$(( ( $(epoch "${end}") - now ) / 86400 ))
  colour="${_c_g}"; mark="✓"
  (( days < warn_days )) && { colour="${_c_y}"; mark="!"; bad=1; }
  (( days < 0 )) && { colour="${_c_r}"; mark="✗"; }
  printf '%s%s%s %-32s %s%4d days%s  %s  %s%s%s\n' "${colour}" "${mark}" "${_c_0}" "${hp}" "${colour}" "${days}" "${_c_0}" "${issuer:-?}" "${_c_d}" "${sans}" "${_c_0}"
done
exit "${bad}"

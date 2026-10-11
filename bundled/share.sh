#!/usr/bin/env bash
# @name: share
# @description: Serve a file or folder and show a QR code — scan it from your phone
# @group: share
# @requires: python3
# @remote: no
# @flags: [path] --port 8000 --tunnel --once
# @dry-run: yes
#
# Serves <path> (default: current folder) on your LAN and prints the URL as a
# QR code in the terminal (qrencode). --tunnel exposes it publicly through a
# Cloudflare quick tunnel (cloudflared, no account) and QR-codes that URL.
# Ctrl-C stops everything.
#
#   ctrl run share                  # this folder, on the LAN
#   ctrl run share build/app.apk    # one file — the QR opens it directly
#   ctrl run share ./dist --tunnel  # public https URL
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
path="." port="" tunnel=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --port)   shift; port="${1:-}" ;;
    --tunnel) tunnel=1 ;;
    -*)       die "Unknown flag: $1" ;;
    *)        path="$1" ;;
  esac
  shift
done
[[ "${CTRL_DRY_RUN}" == "1" || -e "${path}" ]] || die "No such file or folder: ${path}"

# First free port from 8000 up (unless --port)
free_port() {
  local p=8000
  while (( p < 8100 )); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then echo "${p}"; return; fi
    p=$(( p + 1 ))
  done
  echo 8000
}
[[ -n "${port}" ]] || port="$(free_port)"
[[ "${port}" =~ ^[0-9]+$ ]] || die "--port must be a number"

if [[ -d "${path}" ]] || [[ "${CTRL_DRY_RUN}" == "1" && ! -f "${path}" ]]; then
  dir="${path}"; file=""
else
  dir="$(dirname "${path}")"; file="$(basename "${path}")"
fi
urlpath=""; [[ -n "${file}" ]] && urlpath="/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "${file}" 2>/dev/null || echo "${file}")"

lan_ip() {
  local ip=""
  if [[ "$(os)" == darwin ]]; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  else
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    [[ -n "${ip}" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

show_qr() {
  printf '\n  %s%s%s\n\n' "${_c_b}" "$1" "${_c_0}" >&2
  if has qrencode; then qrencode -t ANSIUTF8 -m 2 "$1" >&2
  else warn "install qrencode for a scannable QR code (ctrl run qr --check)"; fi
}

server=(python3 -m http.server "${port}" --bind 0.0.0.0 --directory "${dir}")
if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  run "${server[@]}"
  [[ "${tunnel}" == "1" ]] && run cloudflared tunnel --no-autoupdate --url "http://localhost:${port}"
  exit 0
fi

pids=()
cleanup() { for p in "${pids[@]+"${pids[@]}"}"; do kill "${p}" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

"${server[@]}" >/dev/null 2>&1 &
pids+=("$!")
sleep 0.5
kill -0 "${pids[0]}" 2>/dev/null || die "Could not start the server on port ${port}"

say "Serving ${dir}${file:+/${file}} on port ${port}"
show_qr "http://$(lan_ip):${port}${urlpath}"

if [[ "${tunnel}" == "1" ]]; then
  need_cmd cloudflared
  log="$(mktemp)"
  cloudflared tunnel --no-autoupdate --url "http://localhost:${port}" >"${log}" 2>&1 &
  pids+=("$!")
  say "Opening a public tunnel…"
  public=""
  for _ in $(seq 1 40); do
    public="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${log}" | head -1 || true)"
    [[ -n "${public}" ]] && break
    sleep 0.5
  done
  [[ -n "${public}" ]] || die "cloudflared did not report a URL — see ${log}"
  show_qr "${public}${urlpath}"
fi

say "Ctrl-C to stop"
wait "${pids[0]}"

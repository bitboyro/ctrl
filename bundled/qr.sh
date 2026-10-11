#!/usr/bin/env bash
# @name: qr
# @description: Print any text, URL or Wi-Fi login as a QR code in the terminal
# @group: share
# @requires: qrencode
# @flags: <text> | --wifi SSID [--password P] | --png FILE  (stdin works too)
# @dry-run: yes
#
#   ctrl run qr https://example.com
#   echo "hello" | ctrl run qr
#   ctrl run qr --wifi HomeNet --password hunter2     # phones join by scanning
#   ctrl run qr https://example.com --png qr.png
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
text="" ssid="" pass="" png=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --wifi)     shift; ssid="${1:-}" ;;
    --password) shift; pass="${1:-}" ;;
    --png)      shift; png="${1:-}" ;;
    *)          text="${text:+${text} }$1" ;;
  esac
  shift
done

# Wi-Fi QR format: WIFI:T:WPA;S:<ssid>;P:<pass>;;  (\ ; , : " escaped)
wifi_escape() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
if [[ -n "${ssid}" ]]; then
  if [[ -n "${pass}" ]]; then text="WIFI:T:WPA;S:$(wifi_escape "${ssid}");P:$(wifi_escape "${pass}");;"
  else text="WIFI:T:nopass;S:$(wifi_escape "${ssid}");;"; fi
fi
if [[ -z "${text}" ]]; then
  [[ -t 0 ]] && die "Usage: ctrl run qr <text>   (or pipe text in)"
  text="$(cat)"
fi

if [[ -n "${png}" ]]; then
  run qrencode -o "${png}" -s 10 -m 2 "${text}"
  [[ "${CTRL_DRY_RUN}" == "1" ]] || ok "Saved ${png}"
else
  run qrencode -t ANSIUTF8 -m 2 "${text}"
fi

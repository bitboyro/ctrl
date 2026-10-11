#!/usr/bin/env bash
# @name: shrink
# @description: Re-encode a video to fit a size (e.g. under a chat upload limit)
# @group: media
# @requires: ffmpeg
# @flags: <video> --to 8M --out FILE
# @dry-run: yes
#
# The video bitrate is computed from the target size and the duration
# (ffprobe), leaving 64 kb/s for audio and a 3% container margin.
#
#   ctrl run shrink talk.mov              # → talk.small.mp4 under 8 MB
#   ctrl run shrink talk.mov --to 25M
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
in="" target="8M" out=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --to)     shift; target="${1:-}" ;;
    --out|-o) shift; out="${1:-}" ;;
    -*)       die "Unknown flag: $1" ;;
    *)        [[ -z "${in}" ]] && in="$1" || die "Unexpected argument: $1" ;;
  esac
  shift
done
[[ -n "${in}" ]] || die "Usage: ctrl run shrink <video> [--to 8M]"
[[ "${target}" =~ ^([0-9]+)([KkMmGg]?)$ ]] || die "--to must look like 8M, 500K or 1G"
num="${BASH_REMATCH[1]}"; unit="$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:lower:]' '[:upper:]')"
case "${unit}" in K) bytes=$(( num * 1024 )) ;; G) bytes=$(( num * 1024 * 1024 * 1024 )) ;; *) bytes=$(( num * 1024 * 1024 )) ;; esac
[[ -n "${out}" ]] || out="${in%.*}.small.mp4"

if [[ -n "${SHRINK_DURATION:-}" ]]; then
  duration="${SHRINK_DURATION}"
elif [[ -f "${in}" ]]; then
  duration="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "${in}")"
else
  [[ "${CTRL_DRY_RUN}" == "1" ]] || die "No such file: ${in}"
  duration=60; warn "dry-run: ${in} not found, assuming 60 s"
fi

# kbit/s for video = total bits / seconds − audio, with a 3% margin
vk="$(awk -v b="${bytes}" -v d="${duration}" 'BEGIN{ v = (b*8*0.97/d)/1000 - 64; if (v < 50) v = 50; printf "%d", v }')"
say "Target ${target} over ${duration%.*}s → video ${vk} kb/s + audio 64 kb/s"

run ffmpeg -hide_banner -loglevel warning -stats -y -i "${in}" \
  -c:v libx264 -preset medium -b:v "${vk}k" -maxrate "${vk}k" -bufsize "$(( vk * 2 ))k" \
  -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 64k "${out}"
[[ "${CTRL_DRY_RUN}" == "1" ]] || ok "Saved ${out} ($(human "$(file_size "${out}")"))"

#!/usr/bin/env bash
# @name: gif
# @description: Turn a video into a sharp, small GIF (two-pass palette)
# @group: media
# @requires: ffmpeg
# @flags: <video> --fps 12 --width 960 --from S --to S --out FILE
# @dry-run: yes
#
#   ctrl run gif demo.mp4                 # → demo.gif, 12 fps, max 960 px wide
#   ctrl run gif demo.mp4 --from 3 --to 9 --width 640
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
in="" fps=12 width=960 from="" to="" out=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --fps)    shift; fps="${1:-}" ;;
    --width)  shift; width="${1:-}" ;;
    --from)   shift; from="${1:-}" ;;
    --to)     shift; to="${1:-}" ;;
    --out|-o) shift; out="${1:-}" ;;
    -*)       die "Unknown flag: $1" ;;
    *)        [[ -z "${in}" ]] && in="$1" || die "Unexpected argument: $1" ;;
  esac
  shift
done
[[ -n "${in}" ]] || die "Usage: ctrl run gif <video> [--fps N] [--width PX] [--from S] [--to S]"
[[ "${CTRL_DRY_RUN}" == "1" || -f "${in}" ]] || die "No such file: ${in}"
[[ "${fps}" =~ ^[0-9]+$ && "${width}" =~ ^[0-9]+$ ]] || die "--fps and --width must be whole numbers"
[[ -n "${out}" ]] || out="${in%.*}.gif"

trim=()
[[ -n "${from}" ]] && trim+=(-ss "${from}")
[[ -n "${to}" ]]   && trim+=(-to "${to}")

run ffmpeg -hide_banner -loglevel error -y "${trim[@]+"${trim[@]}"}" -i "${in}" \
  -vf "fps=${fps},scale='min(${width},iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 "${out}"
[[ "${CTRL_DRY_RUN}" == "1" ]] || ok "Saved ${out} ($(human "$(file_size "${out}")"))"

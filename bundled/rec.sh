#!/usr/bin/env bash
# @name: rec
# @description: Record the screen to a small mp4 — every setting inferred (q or Ctrl-C stops)
# @group: media
# @requires: ffmpeg
# @os: darwin linux
# @remote: no
# @flags: --fps 15 --scale 0.5 --crf 30 --time S --audio --region WxH+X+Y --gif --out FILE --open
# @dry-run: yes
#
# Defaults are tuned for sharing: 15 fps, half resolution, H.264 CRF 30 with
# the "veryfast" preset — about 5 MB per minute of screen. The screen and
# resolution are detected: avfoundation on macOS, x11grab on X11, wf-recorder
# on Wayland. --gif also writes a GIF next to the mp4.
#
# Overrides for unusual setups: REC_SCREEN (avfoundation device index),
# REC_SIZE (WxH), REC_DISPLAY (X11 display).
#
#   ctrl run rec                      # record until you press q
#   ctrl run rec --time 30 --gif      # 30 s clip + gif
#   ctrl run rec --region 1280x720+0+0 --fps 30 --scale 1
#   ctrl run rec -n                   # print the exact ffmpeg command
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
fps=15 scale=0.5 crf=30 duration="" audio=0 region="" gif=0 out="" open_after=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --fps)    shift; fps="${1:-}" ;;
    --scale)  shift; scale="${1:-}" ;;
    --crf)    shift; crf="${1:-}" ;;
    --time|-t) shift; duration="${1:-}" ;;
    --audio)  audio=1 ;;
    --region) shift; region="${1:-}" ;;
    --gif)    gif=1 ;;
    --out|-o) shift; out="${1:-}" ;;
    --open)   open_after=1 ;;
    *)        die "Unknown argument: $1 (see: ctrl run rec --help)" ;;
  esac
  shift
done
[[ "${fps}" =~ ^[0-9]+$ ]]          || die "--fps must be a whole number"
[[ "${scale}" =~ ^[0-9.]+$ ]]       || die "--scale must be a number like 0.5"
[[ "${crf}" =~ ^[0-9]+$ ]]          || die "--crf must be a whole number (18 = crisp, 30 = small)"
[[ -z "${duration}" || "${duration}" =~ ^[0-9]+$ ]] || die "--time must be seconds"
[[ -z "${region}" || "${region}" =~ ^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$ ]] || die "--region must look like 1280x720+100+50"
[[ -n "${out}" ]] || out="$(out_name movies mp4)"

# Even dimensions (x264 needs them), scaled
vf="scale=trunc(iw*${scale}/2)*2:trunc(ih*${scale}/2)*2"
if [[ -n "${region}" ]]; then
  IFS='x+' read -r rw rh rx ry <<< "${region}"
  vf="crop=${rw}:${rh}:${rx}:${ry},${vf}"
fi
enc=(-c:v libx264 -preset veryfast -crf "${crf}" -pix_fmt yuv420p -movflags +faststart)
time_args=(); [[ -n "${duration}" ]] && time_args=(-t "${duration}")

# macOS: index of "Capture screen 0" in the avfoundation device list
mac_screen() {
  [[ -n "${REC_SCREEN:-}" ]] && { echo "${REC_SCREEN}"; return; }
  local idx
  idx="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
        | sed -n 's/.*\[\([0-9][0-9]*\)\] Capture screen 0.*/\1/p' | head -1 || true)"
  echo "${idx:-1}"
}

x11_size() {
  [[ -n "${REC_SIZE:-}" ]] && { echo "${REC_SIZE}"; return; }
  local s=""
  has xdpyinfo && s="$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}')"
  [[ -z "${s}" ]] && has xrandr && s="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
  echo "${s:-1920x1080}"
}

case "$(os)" in
  darwin)
    screen="$(mac_screen)"
    input="${screen}:none"; aenc=()
    [[ "${audio}" == "1" ]] && { input="${screen}:0"; aenc=(-c:a aac -b:a 96k); }
    say "Recording screen ${screen} at ${fps} fps, scale ${scale} → ${out}  (press q to stop)"
    run ffmpeg -hide_banner -loglevel warning -stats \
      -f avfoundation -capture_cursor 1 -capture_mouse_clicks 1 -framerate "${fps}" -i "${input}" \
      "${time_args[@]+"${time_args[@]}"}" -vf "${vf}" "${enc[@]}" "${aenc[@]+"${aenc[@]}"}" "${out}"
    ;;
  linux)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && has wf-recorder; then
      geo=(); [[ -n "${region}" ]] && geo=(-g "${rx},${ry} ${rw}x${rh}")
      aud=(); [[ "${audio}" == "1" ]] && aud=(-a)
      say "Recording Wayland output at ${fps} fps → ${out}  (Ctrl-C to stop)"
      if [[ -n "${duration}" ]]; then
        run timeout -s INT "${duration}" wf-recorder "${geo[@]+"${geo[@]}"}" "${aud[@]+"${aud[@]}"}" -r "${fps}" \
          -c libx264 -p crf="${crf}" -p preset=veryfast -F "${vf}" -f "${out}" || true
      else
        run wf-recorder "${geo[@]+"${geo[@]}"}" "${aud[@]+"${aud[@]}"}" -r "${fps}" \
          -c libx264 -p crf="${crf}" -p preset=veryfast -F "${vf}" -f "${out}" || true
      fi
    else
      [[ -n "${DISPLAY:-${REC_DISPLAY:-}}" ]] || die "No DISPLAY — rec needs a graphical session (X11 or Wayland with wf-recorder)"
      size="$(x11_size)"
      aud=(); [[ "${audio}" == "1" ]] && aud=(-f pulse -i default -c:a aac -b:a 96k)
      say "Recording ${size} at ${fps} fps, scale ${scale} → ${out}  (press q to stop)"
      run ffmpeg -hide_banner -loglevel warning -stats \
        -f x11grab -draw_mouse 1 -framerate "${fps}" -video_size "${size}" -i "${REC_DISPLAY:-${DISPLAY}}" \
        "${aud[@]+"${aud[@]}"}" "${time_args[@]+"${time_args[@]}"}" -vf "${vf}" "${enc[@]}" "${out}"
    fi
    ;;
  *) die "rec supports macOS and Linux" ;;
esac

if [[ "${CTRL_DRY_RUN}" != "1" && -f "${out}" ]]; then
  ok "Saved ${out} ($(human "$(file_size "${out}")"))"
fi

if [[ "${gif}" == "1" ]]; then
  gif_out="${out%.*}.gif"
  run ffmpeg -hide_banner -loglevel error -y -i "${out}" \
    -vf "fps=12,scale='min(960,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
    -loop 0 "${gif_out}"
  [[ "${CTRL_DRY_RUN}" != "1" && -f "${gif_out}" ]] && ok "Saved ${gif_out} ($(human "$(file_size "${gif_out}")"))"
fi

[[ "${open_after}" == "1" ]] && open_file "${out}"
exit 0

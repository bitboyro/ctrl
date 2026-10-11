#!/usr/bin/env bash
# @name: snap
# @description: Screenshot the screen or a selected region to ~/Pictures
# @group: media
# @os: darwin linux
# @remote: no
# @flags: --region --window --delay S --clip --out FILE --open
# @dry-run: yes
#
# macOS: screencapture. Linux: grim (+slurp) on Wayland, then maim, scrot or
# ImageMagick import on X11 — the first one installed. --clip also copies the
# image to the clipboard.
#
#   ctrl run snap                 # full screen
#   ctrl run snap --region --clip # drag a box, copy it
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
mode=full delay=0 clip=0 out="" open_after=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --region)  mode=region ;;
    --window)  mode=window ;;
    --delay)   shift; delay="${1:-0}" ;;
    --clip)    clip=1 ;;
    --out|-o)  shift; out="${1:-}" ;;
    --open)    open_after=1 ;;
    *)         die "Unknown argument: $1" ;;
  esac
  shift
done
[[ "${delay}" =~ ^[0-9]+$ ]] || die "--delay must be seconds"
[[ -n "${out}" ]] || out="$(out_name pictures png)"
[[ "${delay}" -gt 0 && "${CTRL_DRY_RUN}" != "1" ]] && { say "Capturing in ${delay}s…"; sleep "${delay}"; }

case "$(os)" in
  darwin)
    flags=(-x)
    [[ "${mode}" == "region" ]] && flags+=(-i)
    [[ "${mode}" == "window" ]] && flags+=(-i -W)
    run screencapture "${flags[@]}" "${out}"
    [[ "${clip}" == "1" ]] && run osascript -e "set the clipboard to (read (POSIX file \"${out}\") as «class PNGf»)"
    ;;
  linux)
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && has grim; then
      if [[ "${mode}" != "full" ]]; then need_cmd slurp; geo="$(slurp)"; run grim -g "${geo}" "${out}"; else run grim "${out}"; fi
      [[ "${clip}" == "1" ]] && has wl-copy && { [[ "${CTRL_DRY_RUN}" == "1" ]] && echo "wl-copy < ${out}" || wl-copy < "${out}"; }
    else
      if has maim; then
        f=(); [[ "${mode}" == "region" ]] && f=(-s); [[ "${mode}" == "window" ]] && f=(-i "$(xdotool getactivewindow 2>/dev/null || echo root)")
        run maim "${f[@]+"${f[@]}"}" "${out}"
      elif has scrot; then
        f=(); [[ "${mode}" == "region" ]] && f=(-s); [[ "${mode}" == "window" ]] && f=(-u)
        run scrot "${f[@]+"${f[@]}"}" "${out}"
      elif has import; then
        f=(-window root); [[ "${mode}" != "full" ]] && f=()
        run import "${f[@]+"${f[@]}"}" "${out}"
      else
        die "No screenshot tool found — install grim (Wayland), maim or scrot"
      fi
      [[ "${clip}" == "1" ]] && has xclip && run xclip -selection clipboard -t image/png -i "${out}"
    fi
    ;;
  *) die "snap supports macOS and Linux" ;;
esac

[[ "${CTRL_DRY_RUN}" == "1" || ! -f "${out}" ]] || ok "Saved ${out}"
[[ "${open_after}" == "1" ]] && open_file "${out}"
exit 0

#!/usr/bin/env bash
# @name: dsh
# @description: Pick a running container (fuzzy) and open a shell in it
# @group: docker
# @requires: docker
# @remote: no
# @flags: [name-filter] --root --cmd CMD
# @dry-run: yes
#
# Uses fzf when installed (with a live `docker logs` preview), otherwise a
# numbered menu. bash is used when the image has it, else sh.
#
#   ctrl run dsh               # pick from all running containers
#   ctrl run dsh api --root    # straight in when only one matches
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
filter="" user_args=() cmd=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --root) user_args=(-u 0) ;;
    --cmd)  shift; cmd="${1:-}" ;;
    -*)     die "Unknown flag: $1" ;;
    *)      filter="$1" ;;
  esac
  shift
done

rows="$(docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' | { if [[ -n "${filter}" ]]; then grep -i -- "${filter}" || true; else cat; fi; })"
[[ -n "${rows}" ]] || die "No running containers${filter:+ matching '${filter}'}"

if [[ "$(printf '%s\n' "${rows}" | wc -l | tr -d ' ')" == "1" ]]; then
  pick="${rows}"
elif has fzf && [[ -t 0 ]]; then
  pick="$(printf '%s\n' "${rows}" | column -t -s $'\t' | fzf --height=40% --reverse --prompt='container> ' \
          --preview 'docker logs --tail 30 {1} 2>&1' --preview-window=down,50%)" || exit 0
else
  i=0; while IFS= read -r r; do i=$(( i + 1 )); printf '  %2d) %s\n' "${i}" "${r//$'\t'/   }" >&2; done <<< "${rows}"
  printf 'container #: ' >&2; read -r n
  pick="$(printf '%s\n' "${rows}" | sed -n "${n}p")"
fi
name="$(awk '{print $1}' <<< "${pick}")"
[[ -n "${name}" ]] || die "Nothing selected"

if [[ -z "${cmd}" ]]; then
  if [[ "${CTRL_DRY_RUN}" == "1" ]] || docker exec "${name}" sh -c 'command -v bash' >/dev/null 2>&1; then cmd="bash"; else cmd="sh"; fi
fi
say "Entering ${name}"
run docker exec -it "${user_args[@]+"${user_args[@]}"}" "${name}" "${cmd}"

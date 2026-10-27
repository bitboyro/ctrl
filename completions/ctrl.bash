# Dynamic ctrl completion. Source this file after installing ctrl.
_ctrl() {
  local current="${COMP_WORDS[COMP_CWORD]}" previous="${COMP_WORDS[COMP_CWORD-1]}"
  local candidates command="" operation="" i word
  local -a config=()
  for ((i=1; i<COMP_CWORD; i++)); do
    word="${COMP_WORDS[i]}"
    case "${word}" in
      --config) config=(--config "${COMP_WORDS[i+1]}"); i=$((i+1)) ;;
      --on) i=$((i+1)) ;;
      --yes|--dry-run|--json|--help) ;;
      *)
        if [[ -z "${command}" ]]; then command="${word}"
        elif [[ -z "${operation}" ]]; then operation="${word}"; fi ;;
    esac
  done
  if [[ "${previous}" == "--on" ]]; then
    candidates="$(ctrl help "${config[@]}" --json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(["local"]+json.load(sys.stdin)["targets"]))' 2>/dev/null)"
  elif [[ -z "${command}" || ( "${command}" == help || "${command}" == run || "${command}" == check ) && -z "${operation}" ]]; then
    candidates="$(ctrl help "${config[@]}" --json 2>/dev/null | python3 -c '
import json,sys
x=json.load(sys.stdin)
print(" ".join(x["core"]+[o["name"] for o in x["operations"]]+[a for o in x["operations"] for a in o["aliases"]]))' 2>/dev/null)"
    [[ "${command}" != help ]] || candidates+=" scripts config security install migration agent examples copy --all"
  else
    case "${command}" in help|run|check) ;; *) operation="${command}" ;; esac
    candidates="$(ctrl help "${operation}" "${config[@]}" --json 2>/dev/null | python3 -c '
import json,sys
x=json.load(sys.stdin); prev=sys.argv[1]; cur=sys.argv[2]
params=x.get("parameters",[])
if cur.startswith("-"):
    print(" ".join([p["flag"] for p in params if "flag" in p]))
else:
    selected=[p for p in params if p.get("flag")==prev]
    if not selected: selected=[p for p in params if "flag" not in p]
    print(" ".join(v for p in selected for v in p.get("choices",[])))
' "${previous}" "${current}" 2>/dev/null)"
  fi
  [[ "${command}" != help || "${current}" != -* ]] || candidates+=" --source"
  [[ "${current}" != -* ]] || candidates+=" --help --on --dry-run --yes --config --json"
  # shellcheck disable=SC2207
  COMPREPLY=( $(compgen -W "${candidates}" -- "${current}") )
}
complete -F _ctrl ctrl

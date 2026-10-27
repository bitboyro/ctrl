#compdef ctrl
# Install as _ctrl in a directory on fpath.
_ctrl() {
  local -a candidates config
  local command='' operation='' word
  local i
  for ((i=2; i<CURRENT; i++)); do
    word="$words[i]"
    case "$word" in
      --config) config=(--config "$words[i+1]"); ((i++)) ;;
      --on) ((i++)) ;;
      --yes|--dry-run|--json|--help) ;;
      *)
        if [[ -z "$command" ]]; then command="$word"
        elif [[ -z "$operation" ]]; then operation="$word"; fi ;;
    esac
  done
  if [[ "$words[CURRENT-1]" == --on ]]; then
    candidates=("${(@f)$(ctrl help "${config[@]}" --json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(["local"]+json.load(sys.stdin)["targets"]))' 2>/dev/null)}")
  elif [[ -z "$command" || ( "$command" == help || "$command" == run || "$command" == check ) && -z "$operation" ]]; then
    candidates=("${(@f)$(ctrl help "${config[@]}" --json 2>/dev/null | python3 -c '
import json,sys
x=json.load(sys.stdin)
print("\n".join(x["core"]+[o["name"] for o in x["operations"]]+[a for o in x["operations"] for a in o["aliases"]]))' 2>/dev/null)}")
    [[ "$command" != help ]] || candidates+=(scripts config security install migration agent examples copy --all)
  else
    case "$command" in help|run|check) ;; *) operation="$command" ;; esac
    candidates=("${(@f)$(ctrl help "$operation" "${config[@]}" --json 2>/dev/null | python3 -c '
import json,sys
x=json.load(sys.stdin); prev=sys.argv[1]; cur=sys.argv[2]; params=x.get("parameters",[])
if cur.startswith("-"): print("\n".join(p["flag"] for p in params if "flag" in p))
else:
    selected=[p for p in params if p.get("flag")==prev] or [p for p in params if "flag" not in p]
    print("\n".join(v for p in selected for v in p.get("choices",[])))
' "$words[CURRENT-1]" "$words[CURRENT]" 2>/dev/null)}")
  fi
  [[ "$command" != help || "$words[CURRENT]" != -* ]] || candidates+=(--source)
  [[ "$words[CURRENT]" != -* ]] || candidates+=(--help --on --dry-run --yes --config --json)
  compadd -- "${candidates[@]}"
}
_ctrl "$@"

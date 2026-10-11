# ctrl bash completion
# Source this file or add to /etc/bash_completion.d/ctrl
# Usage: eval "$(ctrl completion bash)"
# shellcheck disable=SC2207  # COMPREPLY=( $(compgen …) ) is the completion idiom

_ctrl_json_names() { ctrl --json "$@" 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true; }

_ctrl() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword="${COMP_CWORD}"
  }

  local subcommands="build b image i push p release r
    deploy d sync s diff
    ssh remote-status rs remote-logs rl env e cp
    hc health-check run
    init check c list ls info set history h doctor
    mcp completion upgrade version help"

  if [[ "${cword}" -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )
    return
  fi

  local cmd="${words[1]}" i
  for (( i=1; i<cword; i++ )); do
    case "${words[i]}" in
      --dry-run|-n|--verbose|-v|--json|--follow) ;;
      --config) (( i++ )) ;;
      *) cmd="${words[i]}"; break ;;
    esac
  done

  case "${cmd}" in
    build|b|image|i|push|p|release|r)
      COMPREPLY=( $(compgen -W "$(_ctrl_json_names list services) all" -- "${cur}") )
      ;;
    deploy|d)
      COMPREPLY=( $(compgen -W "--release --sync $(_ctrl_json_names list services) all" -- "${cur}") )
      ;;
    hc|health-check)
      COMPREPLY=( $(compgen -W "--wait --count --interval --tcp --port $(_ctrl_json_names list services) $(_ctrl_json_names list machines) all" -- "${cur}") )
      ;;
    ssh|remote-status|rs|remote-logs|rl|env|e|doctor)
      COMPREPLY=( $(compgen -W "$(_ctrl_json_names list machines)" -- "${cur}") )
      ;;
    run)
      if [[ "${prev}" == "--on" ]]; then
        COMPREPLY=( $(compgen -W "local all $(_ctrl_json_names list machines)" -- "${cur}") )
      elif [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "--on --check --show --own --dry-run --yes --tag" -- "${cur}") )
      elif [[ "${cword}" -eq $(( i + 1 )) ]]; then
        COMPREPLY=( $(compgen -W "$(_ctrl_json_names run)" -- "${cur}") )
      fi
      ;;
    list|ls)
      [[ "${cword}" -eq $(( i + 1 )) ]] && COMPREPLY=( $(compgen -W "services machines" -- "${cur}") )
      ;;
    set)
      if [[ "${cword}" -eq $(( i + 1 )) ]]; then
        COMPREPLY=( $(compgen -W "tag default" -- "${cur}") )
      elif [[ "${words[i+1]}" == "tag" && "${cword}" -eq $(( i + 2 )) ]]; then
        COMPREPLY=( $(compgen -W "$(_ctrl_json_names list services)" -- "${cur}") )
      elif [[ "${words[i+1]}" == "default" ]]; then
        COMPREPLY=( $(compgen -W "$(_ctrl_json_names list machines)" -- "${cur}") )
      fi
      ;;
    info)
      COMPREPLY=( $(compgen -W "$(_ctrl_json_names list services) $(_ctrl_json_names list machines)" -- "${cur}") )
      ;;
    help)
      COMPREPLY=( $(compgen -W "build image push release deploy ssh remote-logs hc run cp diff list set doctor" -- "${cur}") )
      ;;
    completion)
      COMPREPLY=( $(compgen -W "bash zsh" -- "${cur}") )
      ;;
  esac
}

complete -F _ctrl ctrl

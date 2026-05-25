# ctrl bash completion
# Source this file or add to /etc/bash_completion.d/ctrl
# Usage: eval "$(ctrl completion bash)"

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
    deploy d redeploy rd sync s sync-deploy sd
    ssh remote-status rs remote-logs rl env e
    health-check hc wait-ready wr smoke-test st
    run script scripts sc
    ping call probe
    doctor
    init check c list ls info machines m diff tag t default history h
    mcp cp gitlab-project-info gitlab-runner-deploy
    completion version help"

  # Level 1: complete subcommand
  if [[ "${cword}" -eq 1 ]]; then
    # Filter out global flags already used
    COMPREPLY=( $(compgen -W "${subcommands}" -- "${cur}") )
    return
  fi

  local cmd="${words[1]}"
  # Strip global flags to get actual subcommand
  local i
  for (( i=1; i<cword; i++ )); do
    case "${words[i]}" in
      --dry-run|-n|--verbose|-v|--json|--follow) ;;
      --config) (( i++ )) ;;
      *) cmd="${words[i]}"; break ;;
    esac
  done

  # Dynamic completions based on subcommand
  case "${cmd}" in
    build|b|image|i|push|p|release|r|health-check|hc|wait-ready|wr|smoke-test|st)
      local svcs; svcs="$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${svcs} all" -- "${cur}") )
      ;;
    deploy|d|redeploy|rd|sync-deploy|sd)
      local targets; targets="$(ctrl --json list 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      local deployments; deployments="$(ctrl info 2>/dev/null | grep -v '^$' || true)"
      # Offer service names and 'all'
      local svcs; svcs="$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${svcs} all" -- "${cur}") )
      ;;
    ssh|remote-status|rs|remote-logs|rl|env|e)
      local machines; machines="$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${machines}" -- "${cur}") )
      ;;
    run)
      local scripts; scripts="$(ctrl scripts --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${scripts}" -- "${cur}") )
      ;;
    script)
      if [[ "${cword}" -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "init list" -- "${cur}") )
      fi
      ;;
    ping|probe|call)
      local svcs; svcs="$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      local machines; machines="$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      case "${cmd}" in
        probe)
          if [[ "${cword}" -eq 2 ]]; then
            COMPREPLY=( $(compgen -W "sniff shell ${svcs} ${machines}" -- "${cur}") )
          elif [[ "${words[2]}" == "sniff" && "${cword}" -eq 3 ]]; then
            COMPREPLY=( $(compgen -W "${svcs}" -- "${cur}") )
          else
            COMPREPLY=( $(compgen -W "--filter --duration --save --host --network --mount --no-network --tcp --http --port" -- "${cur}") )
          fi
          ;;
        *)
          COMPREPLY=( $(compgen -W "${svcs} ${machines}" -- "${cur}") )
          ;;
      esac
      ;;
    tag|t)
      if [[ "${cword}" -eq 2 ]]; then
        local svcs; svcs="$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
        COMPREPLY=( $(compgen -W "${svcs}" -- "${cur}") )
      fi
      ;;
    default)
      local machines; machines="$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${machines}" -- "${cur}") )
      ;;
    info)
      local svcs; svcs="$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      local machines; machines="$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null || true)"
      COMPREPLY=( $(compgen -W "${svcs} ${machines}" -- "${cur}") )
      ;;
    diff|sync|s)
      # Offer deployment target names
      ;;
    help)
      COMPREPLY=( $(compgen -W "build image push release deploy redeploy sync ssh remote-logs remote-status env health-check wait-ready smoke-test run probe ping call doctor diff tag" -- "${cur}") )
      ;;
    completion)
      COMPREPLY=( $(compgen -W "bash zsh" -- "${cur}") )
      ;;
    doctor)
      COMPREPLY=( $(compgen -W "--install" -- "${cur}") )
      ;;
  esac
}

complete -F _ctrl ctrl

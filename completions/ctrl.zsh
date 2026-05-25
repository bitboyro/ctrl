#compdef ctrl
# ctrl zsh completion
# Usage: eval "$(ctrl completion zsh)"
# Or: ctrl completion zsh > "${fpath[1]}/_ctrl"

_ctrl() {
  local curcontext="$curcontext" state line
  typeset -A opt_args

  local -a global_flags
  global_flags=(
    '(-n --dry-run)'{-n,--dry-run}'[print commands without executing]'
    '(-v --verbose)'{-v,--verbose}'[extra debug output]'
    '--json[JSON output]'
    '--follow[tail logs]'
    '--config[override ctrl.yaml location]:config file:_files'
  )

  _arguments -C \
    "${global_flags[@]}" \
    '1: :_ctrl_commands' \
    '*:: :->args'

  case "${state}" in
    args)
      case "${words[1]}" in
        build|b|image|i|push|p|release|r|health-check|hc|wait-ready|wr|smoke-test|st)
          _ctrl_services_and_all
          ;;
        deploy|d|redeploy|rd|sync-deploy|sd)
          _ctrl_services_and_all
          ;;
        ssh|remote-status|rs|remote-logs|rl|env|e)
          _ctrl_machines
          ;;
        run)
          _ctrl_scripts
          ;;
        script)
          _ctrl_script_subcommands
          ;;
        ping)
          _ctrl_services_and_machines
          ;;
        call)
          if [[ "${CURRENT}" -eq 2 ]]; then
            _ctrl_services
          fi
          ;;
        probe)
          _ctrl_probe_args
          ;;
        tag|t)
          if [[ "${CURRENT}" -eq 2 ]]; then
            _ctrl_services
          fi
          ;;
        default)
          _ctrl_machines
          ;;
        info)
          _ctrl_services_and_machines
          ;;
        help)
          local -a help_cmds
          help_cmds=(build image push release deploy redeploy sync ssh remote-logs remote-status env health-check wait-ready smoke-test run probe ping call doctor diff tag)
          _values 'command' "${help_cmds[@]}"
          ;;
        completion)
          _values 'shell' bash zsh
          ;;
        doctor)
          _arguments '--install[auto-install missing tools]'
          ;;
      esac
      ;;
  esac
}

_ctrl_commands() {
  local -a cmds
  cmds=(
    'build:build service code locally'
    'b:alias for build'
    'image:build Docker image'
    'i:alias for image'
    'push:push image to registry'
    'p:alias for push'
    'release:build + image + push'
    'r:alias for release'
    'deploy:deploy to target'
    'd:alias for deploy'
    'redeploy:release + deploy'
    'rd:alias for redeploy'
    'sync:sync files to target'
    's:alias for sync'
    'sync-deploy:sync + deploy'
    'sd:alias for sync-deploy'
    'ssh:interactive SSH or remote command'
    'remote-status:docker compose ps'
    'rs:alias for remote-status'
    'remote-logs:tail docker compose logs'
    'rl:alias for remote-logs'
    'env:show container env vars'
    'e:alias for env'
    'health-check:HTTP health check'
    'hc:alias for health-check'
    'wait-ready:poll until healthy'
    'wr:alias for wait-ready'
    'smoke-test:run smoke test scripts'
    'st:alias for smoke-test'
    'run:run a named script'
    'script:manage scripts'
    'scripts:list scripts'
    'sc:alias for scripts'
    'ping:HTTP/TCP ping by service or machine name'
    'call:authenticated REST call'
    'probe:connectivity check, tcpdump, or tools shell'
    'doctor:pre-flight dependency check'
    'init:generate ctrl.yaml interactively'
    'check:validate ctrl.yaml'
    'c:alias for check'
    'list:list services'
    'ls:alias for list'
    'info:project/machine/service detail'
    'machines:list machines'
    'm:alias for machines'
    'diff:drift detection'
    'tag:update service tag in ctrl.yaml'
    't:alias for tag'
    'default:set default machine or deployment'
    'history:show audit journal'
    'h:alias for history'
    'mcp:start stdio MCP server'
    'cp:copy files with rsync'
    'completion:print shell completion script'
    'version:print ctrl version'
    'help:show help'
  )
  _describe 'ctrl command' cmds
}

_ctrl_services() {
  local -a svcs
  svcs=( ${(f)"$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'service' "${svcs[@]}"
}

_ctrl_services_and_all() {
  local -a svcs
  svcs=( ${(f)"$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  svcs+=(all)
  _values 'service' "${svcs[@]}"
}

_ctrl_machines() {
  local -a machines
  machines=( ${(f)"$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'machine' "${machines[@]}"
}

_ctrl_services_and_machines() {
  local -a items
  items=( ${(f)"$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  items+=( ${(f)"$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'target' "${items[@]}"
}

_ctrl_scripts() {
  local -a scripts
  scripts=( ${(f)"$(ctrl scripts --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'script' "${scripts[@]}"
}

_ctrl_script_subcommands() {
  if [[ "${CURRENT}" -eq 2 ]]; then
    _values 'subcommand' 'init:create script from template' 'list:list scripts'
  fi
}

_ctrl_probe_args() {
  if [[ "${CURRENT}" -eq 2 ]]; then
    local -a items
    items=(sniff shell)
    items+=( ${(f)"$(ctrl list --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
    items+=( ${(f)"$(ctrl machines --json 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
    _values 'subcommand or target' "${items[@]}"
  elif [[ "${words[2]}" == "sniff" && "${CURRENT}" -eq 3 ]]; then
    _ctrl_services
  else
    _arguments \
      '--filter[tcpdump filter expression]:filter' \
      '--duration[capture duration in seconds]:seconds' \
      '--save[save to .local/captures/]' \
      '--host[use host tcpdump instead of container]' \
      '--network[Docker network to join]:network' \
      '--mount[bind-mount host path]:src\:dst' \
      '--no-network[isolated, no network]' \
      '--tcp[TCP probe]' \
      '--http[HTTP probe]' \
      '--port[port override]:port'
  fi
}

_ctrl "$@"

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
        build|b|image|i|push|p|release|r)
          _ctrl_services_and_all
          ;;
        deploy|d)
          _arguments '--release[build + image + push first]' '--sync[rsync sync.paths first]' '*: :_ctrl_services_and_all'
          ;;
        hc|health-check)
          _arguments \
            '--wait[poll until healthy]:seconds' \
            '--count[latency stats over N requests]:count' \
            '--interval[seconds between samples]:seconds' \
            '--tcp[TCP check instead of HTTP]' \
            '--port[TCP port]:port' \
            '*: :_ctrl_services_and_machines'
          ;;
        ssh|remote-status|rs|remote-logs|rl|env|e|doctor)
          _ctrl_machines
          ;;
        run)
          if [[ "${CURRENT}" -eq 2 ]]; then
            _ctrl_scripts
          else
            _arguments \
              '--on[where to run]:target:_ctrl_on_targets' \
              '--check[pre-flight only]' \
              '--show[header, source, diff vs bundled]' \
              '--own[copy a bundled script into scripts/]' \
              '(-n --dry-run)'{-n,--dry-run}'[print what would run]' \
              '--yes[confirm sudo scripts]' \
              '*:argument:_files'
          fi
          ;;
        list|ls)
          [[ "${CURRENT}" -eq 2 ]] && _values 'what' services machines
          ;;
        set)
          if [[ "${CURRENT}" -eq 2 ]]; then
            _values 'what' 'tag[service image tag]' 'default[default machine or deployment]'
          elif [[ "${words[2]}" == "tag" && "${CURRENT}" -eq 3 ]]; then
            _ctrl_services
          elif [[ "${words[2]}" == "default" ]]; then
            _ctrl_machines
          fi
          ;;
        info)
          _ctrl_services_and_machines
          ;;
        help)
          _values 'command' build image push release deploy ssh remote-logs hc run cp diff list set doctor
          ;;
        completion)
          _values 'shell' bash zsh
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
    'deploy:deploy to target (--release, --sync)'
    'd:alias for deploy'
    'sync:sync files to target'
    's:alias for sync'
    'diff:drift detection'
    'ssh:interactive SSH or remote command'
    'remote-status:docker compose ps'
    'rs:alias for remote-status'
    'remote-logs:tail docker compose logs'
    'rl:alias for remote-logs'
    'env:show container env vars'
    'e:alias for env'
    'cp:copy files with rsync'
    'hc:health, wait, latency, TCP checks'
    'run:run any script — project or bundled — on any hosts'
    'init:generate ctrl.yaml interactively'
    'check:validate ctrl.yaml'
    'c:alias for check'
    'list:list services or machines'
    'ls:alias for list'
    'info:project/machine/service detail'
    'set:set tag or default'
    'history:show audit journal'
    'h:alias for history'
    'doctor:tools, env vars and config (or a host)'
    'mcp:start stdio MCP server'
    'completion:print shell completion script'
    'upgrade:upgrade ctrl'
    'version:print ctrl version'
    'help:show help'
  )
  _describe 'ctrl command' cmds
}

_ctrl_services() {
  local -a svcs
  svcs=( ${(f)"$(ctrl --json list services 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'service' "${svcs[@]}"
}

_ctrl_services_and_all() {
  local -a svcs
  svcs=( ${(f)"$(ctrl --json list services 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} all )
  _values 'service' "${svcs[@]}"
}

_ctrl_machines() {
  local -a machines
  machines=( ${(f)"$(ctrl --json list machines 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'machine' "${machines[@]}"
}

_ctrl_services_and_machines() {
  local -a items
  items=( ${(f)"$(ctrl --json list services 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  items+=( ${(f)"$(ctrl --json list machines 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'target' "${items[@]}"
}

_ctrl_scripts() {
  local -a scripts
  scripts=( ${(f)"$(ctrl --json run 2>/dev/null | command jq -r '.[] | .name + ":" + .description' 2>/dev/null)"} )
  _describe 'script' scripts
}

_ctrl_on_targets() {
  local -a t
  t=( local all ${(f)"$(ctrl --json list machines 2>/dev/null | command jq -r '.[].name' 2>/dev/null)"} )
  _values 'target' "${t[@]}"
}

_ctrl "$@"

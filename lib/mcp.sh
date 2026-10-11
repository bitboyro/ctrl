#!/usr/bin/env bash
# mcp.sh — ctrl stdio MCP server (JSON-RPC 2.0)
# Register: { "mcpServers": { "ctrl": { "command": "ctrl", "args": ["mcp"] } } }

_mcp_tools_list() {
  cat << 'EOF'
{
  "tools": [
    {"name":"list_services","description":"List all services defined in ctrl.yaml with kind, image, and tag","inputSchema":{"type":"object","properties":{}}},
    {"name":"list_machines","description":"List all machines (SSH hosts) defined in ctrl.yaml","inputSchema":{"type":"object","properties":{}}},
    {"name":"get_info","description":"Get project info, or detail about a specific service or machine","inputSchema":{"type":"object","properties":{"target":{"type":"string","description":"Optional: service name or machine name"}}}},
    {"name":"check_config","description":"Validate ctrl.yaml structure, names, file references and script headers","inputSchema":{"type":"object","properties":{}}},
    {"name":"build_service","description":"Build service code locally","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"}},"required":["service"]}},
    {"name":"release_service","description":"Build code, build image, and push to registry","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"}},"required":["service"]}},
    {"name":"deploy_service","description":"Pull and start services on a deployment target","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"},"deployment":{"type":"string","description":"Deployment target name (optional, uses default)"}},"required":["service"]}},
    {"name":"diff_deployment","description":"Compare declared image:tag vs running containers on a deployment target","inputSchema":{"type":"object","properties":{"deployment":{"type":"string","description":"Deployment target name (optional, uses default)"}}}},
    {"name":"health_check","description":"Health check for a service, a machine (TCP), or all services","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service or machine name, or 'all' (default)"}}}},
    {"name":"run_list","description":"List every runnable script: project scripts and ctrl's bundled library (name, source, group, description, os, remote, sudo)","inputSchema":{"type":"object","properties":{"tag":{"type":"string","description":"Optional tag filter"}}}},
    {"name":"run","description":"Run a script (project or bundled) locally or on hosts. Scripts marked sudo need yes=true. Use check=true for pre-flight only and dry_run=true to see the exact commands.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Script name (see run_list)"},"args":{"type":"array","items":{"type":"string"},"description":"Arguments passed to the script"},"on":{"type":"string","description":"local (default) | deployment or machine | a,b | @tag | all"},"check":{"type":"boolean","description":"Pre-flight only (os, tools, env, sudo)"},"dry_run":{"type":"boolean","description":"Print what would run"},"yes":{"type":"boolean","description":"Confirm scripts that use sudo"}},"required":["name"]}},
    {"name":"update_tag","description":"Update the image tag for a service in ctrl.yaml","inputSchema":{"type":"object","properties":{"service":{"type":"string"},"tag":{"type":"string"}},"required":["service","tag"]}},
    {"name":"get_history","description":"Show the last N audit journal entries","inputSchema":{"type":"object","properties":{"count":{"type":"integer","description":"Number of entries (default 20)"}}}}
  ]
}
EOF
}

_mcp_capture() {
  local exit_code=0
  "$@" 2>&1 || exit_code=$?
  echo "__EXIT_CODE__${exit_code}"
}

# Run one tool. Each branch runs its work in a subshell ($(…)), so a fail()
# deep inside ctrl ends that call, not the server. Each branch also declares
# its output kind: json (passed through) or text (wrapped as {"text": …}).
_mcp_run_tool() {
  local tool="$1"
  local params="$2"

  local output="" exit_code=0 kind=text
  # shellcheck disable=SC2034
  CTRL_JSON=1

  # Reject unsafe parameter values up front: they reach yq expressions and
  # remote shell commands.
  local _field _val _part
  for _field in service deployment name tag target; do
    _val="$(echo "${params}" | jq -r ".${_field} // \"\"" 2>/dev/null || true)"
    [[ -z "${_val}" || "${_val}" == "null" ]] && continue
    IFS=',' read -r -a _parts <<< "${_val}"
    for _part in "${_parts[@]}"; do
      _part="${_part// /}"
      ctrl_is_valid_name "${_part}" || {
        printf '{"error":%s}' "$(printf 'invalid %s: %s' "${_field}" "${_val}" | jq -R -s .)"; return 1; }
    done
  done
  _val="$(echo "${params}" | jq -r '.count // 20' 2>/dev/null || echo 20)"
  [[ "${_val}" =~ ^[0-9]+$ ]] || { echo '{"error":"count must be a whole number"}'; return 1; }

  _p() { echo "${params}" | jq -r "$1" 2>/dev/null || true; }

  case "${tool}" in
    list_services)
      kind=json; output="$(ctrl_list_json 2>&1)" || exit_code=$?
      ;;
    list_machines)
      kind=json; output="$(ctrl_list_machines 2>&1)" || exit_code=$?
      ;;
    get_info)
      kind=json; output="$(ctrl_info "$(_p '.target // ""')" 2>&1)" || exit_code=$?
      ;;
    check_config)
      kind=json; output="$(ctrl_check 2>&1)" || exit_code=$?
      ;;
    build_service)
      local svc; svc="$(_p '.service // ""')"
      [[ -n "${svc}" ]] || { echo '{"error":"service is required"}'; return 1; }
      output="$( { _s="$(ctrl_resolve_services "${svc}")" || exit 1; read -r -a svcs <<< "${_s}"; for s in "${svcs[@]}"; do build_code_service "${s}" || exit 1; done; } 2>&1 )" || exit_code=$?
      ;;
    release_service)
      local svc; svc="$(_p '.service // ""')"
      [[ -n "${svc}" ]] || { echo '{"error":"service is required"}'; return 1; }
      output="$( { _s="$(ctrl_resolve_services "${svc}")" || exit 1; read -r -a svcs <<< "${_s}"; f=0; for s in "${svcs[@]}"; do release_service "${s}" || f=1; done; exit "${f}"; } 2>&1 )" || exit_code=$?
      ;;
    deploy_service)
      local svc dep; svc="$(_p '.service // "all"')"; dep="$(_p '.deployment // ""')"
      output="$( { resolve_deployment "${dep}" && _s="$(ctrl_resolve_services "${svc}")" && read -r -a svcs <<< "${_s}" && deploy_services "${svcs[@]}"; } 2>&1 )" || exit_code=$?
      ;;
    diff_deployment)
      local dep; dep="$(_p '.deployment // ""')"
      kind=json; output="$( { resolve_deployment "${dep}" && diff_deployment; } 2>&1 )" || exit_code=$?
      ;;
    health_check)
      local svc; svc="$(_p '.service // "all"')"
      output="$(ctrl_hc "${svc}" 2>&1)" || exit_code=$?
      ;;
    run_list)
      local tag; tag="$(_p '.tag // ""')"
      kind=json; output="$(ctrl_run_list "${tag}" 2>&1)" || exit_code=$?
      ;;
    run|run_script)
      local name; name="$(_p '.name // ""')"
      [[ -n "${name}" ]] || { echo '{"error":"name is required"}'; return 1; }
      local -a run_args=("${name}")
      local on; on="$(_p '.on // ""')"
      [[ -n "${on}" ]] && run_args+=(--on "${on}")
      [[ "$(_p '.check // false')" == "true" ]]   && run_args+=(--check)
      [[ "$(_p '.dry_run // false')" == "true" ]] && run_args+=(--dry-run)
      [[ "$(_p '.yes // false')" == "true" ]]     && run_args+=(--yes)
      run_args+=(--)
      local a
      while IFS= read -r a; do run_args+=("${a}"); done < <(echo "${params}" | jq -r '.args[]? | tostring' 2>/dev/null)
      # shellcheck disable=SC2034  # read by ctrl_run's listing/output helpers
      CTRL_JSON=0
      output="$(ctrl_run "${run_args[@]}" < /dev/null 2>&1)" || exit_code=$?
      ;;
    update_tag)
      local svc tag; svc="$(_p '.service // ""')"; tag="$(_p '.tag // ""')"
      [[ -n "${svc}" && -n "${tag}" ]] || { echo '{"error":"service and tag are required"}'; return 1; }
      output="$(ctrl_set_tag "${svc}" "${tag}" 2>&1)" || exit_code=$?
      ;;
    get_history)
      output="$(show_history "$(_p '.count // 20')" 2>&1)" || exit_code=$?
      ;;
    *)
      echo '{"error":"unknown tool"}'; return 1
      ;;
  esac

  if [[ "${exit_code}" -ne 0 ]]; then
    printf '{"error":%s,"exit_code":%d}' "$(printf '%s' "${output}" | jq -R -s .)" "${exit_code}"
  elif [[ "${kind}" == "json" ]] && printf '%s' "${output}" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "${output}"
  else
    printf '{"text":%s}' "$(printf '%s' "${output}" | jq -R -s .)"
  fi
}

ctrl_list_json() {
  local -a rows=()
  while IFS= read -r svc; do
    local kind; kind="$(ctrl_service_kind "${svc}")"
    local img; img="$(ctrl_service_field "${svc}" '.image // ""')"
    local tag; tag="$(ctrl_service_field "${svc}" '.tag // "latest"')"
    local desc; desc="$(ctrl_service_field "${svc}" '.description // ""')"
    rows+=("$(jq -n --arg name "${svc}" --arg kind "${kind}" --arg image "${img}" --arg tag "${tag}" --arg description "${desc}" '{name:$name,kind:$kind,image:$image,tag:$tag,description:$description}')")
  done < <(ctrl_service_names)
  printf '[%s]\n' "$(IFS=,; echo "${rows[*]+"${rows[*]}"}")"
}

ctrl_mcp_serve() {
  require_cmd jq
  # shellcheck disable=SC2034  # read by _find_config in core.sh
  CTRL_CONFIG_OPTIONAL=1   # bundled scripts are useful outside a project too
  load_config
  load_extensions

  local line
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue

    local id method params
    id="$(echo "${line}"     | jq -r '.id // null')"
    method="$(echo "${line}" | jq -r '.method // ""')"
    params="$(echo "${line}" | jq -c '.params // {}')"

    local response
    case "${method}" in
      initialize)
        response="$(jq -cn --argjson id "${id}" '{jsonrpc:"2.0",id:$id,result:{protocolVersion:"2024-11-05",capabilities:{tools:{}},serverInfo:{name:"ctrl",version:"'"${CTRL_VERSION}"'"}}}')"
        ;;
      tools/list)
        local tools_json; tools_json="$(_mcp_tools_list)"
        response="$(jq -cn --argjson id "${id}" --argjson t "${tools_json}" '{jsonrpc:"2.0",id:$id,result:$t}')"
        ;;
      tools/call)
        local tool_name; tool_name="$(echo "${params}" | jq -r '.name // ""')"
        local tool_args; tool_args="$(echo "${params}" | jq -c '.arguments // {}')"
        # A tool prints exactly one JSON value, even when it fails; anything
        # else becomes a generic error so the server never dies on bad output.
        local result; result="$(_mcp_run_tool "${tool_name}" "${tool_args}" 2>/dev/null)" || true
        printf '%s' "${result}" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1 || result='{"error":"tool execution failed"}'
        response="$(jq -cn --argjson id "${id}" --argjson r "${result}" '{jsonrpc:"2.0",id:$id,result:{content:[{type:"text",text:($r|tostring)}]}}')"
        ;;
      notifications/*)
        continue ;;
      *)
        response="$(jq -cn --argjson id "${id}" '{jsonrpc:"2.0",id:$id,error:{code:-32601,message:"Method not found"}}')"
        ;;
    esac

    echo "${response}"
  done
}

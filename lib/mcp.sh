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
    {"name":"check_config","description":"Validate ctrl.yaml structure and file references","inputSchema":{"type":"object","properties":{}}},
    {"name":"build_service","description":"Build service code locally","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"}},"required":["service"]}},
    {"name":"release_service","description":"Build code, build image, and push to registry","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"}},"required":["service"]}},
    {"name":"deploy_service","description":"Pull and start services on a deployment target","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all'"},"deployment":{"type":"string","description":"Deployment target name (optional, uses default)"}},"required":["service"]}},
    {"name":"diff_deployment","description":"Compare declared image:tag vs running containers on a deployment target","inputSchema":{"type":"object","properties":{"deployment":{"type":"string","description":"Deployment target name (optional, uses default)"}}}},
    {"name":"health_check","description":"Run health check for a service or all services","inputSchema":{"type":"object","properties":{"service":{"type":"string","description":"Service name or 'all' (optional, defaults to all)"}}}},
    {"name":"run_script","description":"Run a named script from ctrl.yaml scripts:","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Script name"}},"required":["name"]}},
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

_mcp_run_tool() {
  local tool="$1"
  local params="$2"

  local output exit_code=0
  CTRL_JSON=1

  case "${tool}" in
    list_services)
      output="$(ctrl_list_json 2>&1)" || exit_code=$?
      ;;
    list_machines)
      output="$(ctrl_list_machines 2>&1)" || exit_code=$?
      ;;
    get_info)
      local target; target="$(echo "${params}" | yq '.target // ""' 2>/dev/null || true)"
      output="$(ctrl_info "${target}" 2>&1)" || exit_code=$?
      ;;
    check_config)
      output="$(ctrl_check 2>&1)" || exit_code=$?
      ;;
    build_service)
      local svc; svc="$(echo "${params}" | yq '.service // ""' 2>/dev/null || true)"
      [[ -n "${svc}" ]] || { echo '{"error":"service is required"}'; return 1; }
      local -a svcs=()
      read -r -a svcs <<< "$(ctrl_resolve_services "${svc}")"
      local out=""; for s in "${svcs[@]}"; do out+="$(build_code_service "${s}" 2>&1)"; done
      output="${out}"; exit_code=$?
      ;;
    release_service)
      local svc; svc="$(echo "${params}" | yq '.service // ""' 2>/dev/null || true)"
      [[ -n "${svc}" ]] || { echo '{"error":"service is required"}'; return 1; }
      local -a svcs=(); read -r -a svcs <<< "$(ctrl_resolve_services "${svc}")"
      local out=""; for s in "${svcs[@]}"; do out+="$(release_service "${s}" 2>&1)" || exit_code=$?; done
      output="${out}"
      ;;
    deploy_service)
      local svc; svc="$(echo "${params}" | yq '.service // "all"' 2>/dev/null || true)"
      local dep; dep="$(echo "${params}" | yq '.deployment // ""' 2>/dev/null || true)"
      resolve_deployment "${dep}"
      local -a svcs=(); read -r -a svcs <<< "$(ctrl_resolve_services "${svc}")"
      output="$(deploy_services "${svcs[@]}" 2>&1)" || exit_code=$?
      ;;
    diff_deployment)
      local dep; dep="$(echo "${params}" | yq '.deployment // ""' 2>/dev/null || true)"
      resolve_deployment "${dep}"
      output="$(diff_deployment 2>&1)" || exit_code=$?
      ;;
    health_check)
      local svc; svc="$(echo "${params}" | yq '.service // "all"' 2>/dev/null || true)"
      local -a svcs=(); read -r -a svcs <<< "$(ctrl_resolve_services "${svc}")"
      local out=""; for s in "${svcs[@]}"; do out+="$(health_check_service "${s}" 2>&1)" || exit_code=$?; done
      output="${out}"
      ;;
    run_script)
      local name; name="$(echo "${params}" | yq '.name // ""' 2>/dev/null || true)"
      [[ -n "${name}" ]] || { echo '{"error":"name is required"}'; return 1; }
      output="$(run_script "${name}" 2>&1)" || exit_code=$?
      ;;
    update_tag)
      local svc; svc="$(echo "${params}" | yq '.service // ""' 2>/dev/null || true)"
      local tag; tag="$(echo "${params}" | yq '.tag // ""' 2>/dev/null || true)"
      [[ -n "${svc}" && -n "${tag}" ]] || { echo '{"error":"service and tag are required"}'; return 1; }
      output="$(ctrl_set_tag "${svc}" "${tag}" 2>&1)" || exit_code=$?
      ;;
    get_history)
      local count; count="$(echo "${params}" | yq '.count // 20' 2>/dev/null || echo "20")"
      output="$(show_history "${count}" 2>&1)" || exit_code=$?
      ;;
    *)
      echo '{"error":"unknown tool"}'; return 1
      ;;
  esac

  if [[ "${exit_code}" -ne 0 ]]; then
    printf '{"error":%s}' "$(printf '%s' "${output}" | jq -R -s .)"
  else
    # If output is already JSON, pass through; otherwise wrap as text
    if echo "${output}" | jq . >/dev/null 2>&1; then
      echo "${output}"
    else
      printf '{"text":%s}' "$(printf '%s' "${output}" | jq -R -s .)"
    fi
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
        local result; result="$(_mcp_run_tool "${tool_name}" "${tool_args}" 2>/dev/null || echo '{"error":"tool execution failed"}')"
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

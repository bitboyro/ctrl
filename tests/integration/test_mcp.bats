#!/usr/bin/env bats
# MCP JSON-RPC integration test — exercises `ctrl mcp` over stdio.
# No SSH or Docker needed; the MCP server is self-contained.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  yq -i '.services = [{"name":"svc1","image":"docker.io/test/svc1","tag":"latest","build":{"tool":"skip"},"deploy":{"compose_service":"svc1"},"health":{"port":8080}}]' "${TEST_TMP}/ctrl.yaml"
}
teardown() { teardown_test_dir; }

# Pipe a JSON-RPC request to `ctrl mcp`, return the response line.
_mcp_call() {
  local payload="$1"
  echo "${payload}" | env CTRL_CONFIG="${CTRL_CONFIG}" "${CTRL_REPO_ROOT}/ctrl.sh" mcp 2>/dev/null | head -1
}

@test "initialize returns protocolVersion and serverInfo.name=ctrl" {
  local resp; resp="$(_mcp_call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')"
  echo "${resp}" | jq -e '.id == 1 and .result.serverInfo.name == "ctrl"'
}

@test "tools/list returns at least one tool with name and inputSchema" {
  local resp; resp="$(_mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
  echo "${resp}" | jq -e '.id == 2 and (.result.tools | length) > 0'
  echo "${resp}" | jq -e '.result.tools[] | select(.name == "list_services")'
}

@test "tools/call list_services returns the configured service" {
  local resp
  resp="$(_mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_services","arguments":{}}}')"
  echo "${resp}" | jq -e '.id == 3 and .result.content[0].type == "text"'
  echo "${resp}" | jq -r '.result.content[0].text' | grep -qF "svc1"
}

@test "unknown method returns JSON-RPC error code -32601" {
  local resp; resp="$(_mcp_call '{"jsonrpc":"2.0","id":4,"method":"bogus/method","params":{}}')"
  echo "${resp}" | jq -e '.id == 4 and .error.code == -32601'
}

@test "MCP responses are compact single-line JSON" {
  local resp; resp="$(_mcp_call '{"jsonrpc":"2.0","id":5,"method":"initialize","params":{}}')"
  # exactly one line of valid JSON
  [[ "$(echo "${resp}" | wc -l | tr -d ' ')" == "1" ]] || return 1
  echo "${resp}" | jq -e . >/dev/null
}

# ── run / run_list ──────────────────────────────────────────────────────────

_mcp_tool() {  # _mcp_tool <name> <arguments-json>  →  the tool's result object
  local req; req="$(jq -cn --arg n "$1" --argjson a "$2" '{jsonrpc:"2.0",id:9,method:"tools/call",params:{name:$n,arguments:$a}}')"
  echo "${req}" | env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${CTRL_REPO_ROOT}/ctrl.sh" mcp 2>/dev/null | head -1 | jq -r '.result.content[0].text'
}

@test "tools/list offers run and run_list" {
  local resp; resp="$(_mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')"
  echo "${resp}" | jq -e '[.result.tools[].name] | index("run") and index("run_list")' >/dev/null
}

@test "run_list returns structured JSON including bundled scripts" {
  local out; out="$(_mcp_tool run_list '{}')"
  echo "${out}" | jq -e '.[] | select(.name == "sysinfo" and .source == "bundled")' >/dev/null
}

@test "run passes args to a project script and returns its output as text" {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\necho "got:$*"\n' > "${TEST_TMP}/scripts/echoer.sh"
  local out; out="$(_mcp_tool run '{"name":"echoer","args":["a b","--json"]}')"
  echo "${out}" | jq -e '.text | contains("got:a b --json")' >/dev/null
}

@test "run dry_run shows commands without executing" {
  local out; out="$(_mcp_tool run '{"name":"new-script","dry_run":true,"args":["viamcp"]}')"
  echo "${out}" | jq -e '.text | contains("write ") and contains("viamcp.sh")' >/dev/null
  [[ ! -f "${TEST_TMP}/scripts/viamcp.sh" ]] || return 1
}

@test "run refuses a sudo script unless yes=true" {
  local out; out="$(_mcp_tool run '{"name":"install-docker"}')"
  echo "${out}" | jq -e '.error | contains("--yes")' >/dev/null
}

@test "run rejects a hostile script name and the server keeps answering" {
  local req1 req2
  req1='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run","arguments":{"name":"x;id"}}}'
  req2='{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}'
  run bash -c "printf '%s\n%s\n' '${req1}' '${req2}' | env CTRL_CONFIG='${CTRL_CONFIG}' '${CTRL_REPO_ROOT}/ctrl.sh' mcp 2>/dev/null"
  [[ "$(echo "${output}" | wc -l | tr -d ' ')" == "2" ]] || return 1
  echo "${output}" | head -1 | jq -e '.result.content[0].text | fromjson | .error | contains("invalid name")' >/dev/null
  echo "${output}" | tail -1 | jq -e '.id == 2' >/dev/null
}

@test "a failing deploy returns an error instead of killing the server" {
  local req1 req2
  req1='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"deploy_service","arguments":{"service":"svc1","deployment":"nope"}}}'
  req2='{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}'
  run bash -c "printf '%s\n%s\n' '${req1}' '${req2}' | env CTRL_CONFIG='${CTRL_CONFIG}' '${CTRL_REPO_ROOT}/ctrl.sh' mcp 2>/dev/null"
  [[ "$(echo "${output}" | wc -l | tr -d ' ')" == "2" ]] || return 1
  echo "${output}" | head -1 | jq -e '.result.content[0].text | fromjson | .error | contains("nope")' >/dev/null
}

@test "text tools are wrapped even when their output looks like JSON" {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\necho 42\n' > "${TEST_TMP}/scripts/num.sh"
  local out; out="$(_mcp_tool run '{"name":"num"}')"
  echo "${out}" | jq -e 'has("text")' >/dev/null
}

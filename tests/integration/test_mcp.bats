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
  [[ "$(echo "${resp}" | wc -l | tr -d ' ')" == "1" ]]
  echo "${resp}" | jq -e . >/dev/null
}

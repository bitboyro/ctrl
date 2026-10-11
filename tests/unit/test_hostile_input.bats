#!/usr/bin/env bats
# Unit tests for input hardening — hostile names must be rejected before they
# reach yq expressions, remote shell commands or ctrl.yaml writes.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  yq -i '.services = [{"name":"api","image":"docker.io/t/api","tag":"v1.0.0","health":{"url":"http://localhost:8080/health"}}]' \
    "${TEST_TMP}/ctrl.yaml"
  cp "${TEST_TMP}/ctrl.yaml" "${TEST_TMP}/ctrl.yaml.orig"
  export PWNED="${TEST_TMP}/pwned"
}

teardown() { teardown_test_dir; }

assert_not_pwned() {
  [[ ! -e "${PWNED}" ]] || { echo "injected command ran" >&2; return 1; }
}

assert_yaml_unchanged() {
  diff -q "${TEST_TMP}/ctrl.yaml" "${TEST_TMP}/ctrl.yaml.orig" >/dev/null || {
    echo "ctrl.yaml was modified" >&2; return 1; }
}

# ── ctrl_valid_name ─────────────────────────────────────────────────────────

@test "ctrl_is_valid_name accepts plain tokens" {
  source_libs core.sh
  local n
  for n in api my-svc worker_2 v1.2.3 a; do
    ctrl_is_valid_name "${n}" || { echo "rejected: ${n}" >&2; return 1; }
  done
}

@test "ctrl_is_valid_name rejects quotes, substitutions, separators and spaces" {
  source_libs core.sh
  local n
  for n in 'a"b' '$(x)' '`x`' ';rm' 'a b' 'a|b' '../x' '-flag' '' 'a\b' "a'b"; do
    if ctrl_is_valid_name "${n}"; then echo "accepted: ${n}" >&2; return 1; fi
  done
}

# ── yq write paths ──────────────────────────────────────────────────────────

@test "ctrl tag rejects a tag that tries to break out of the yq string" {
  run_ctrl set tag api 'v1" | .meta.project = "owned'
  assert_failure
  assert_contains "Invalid tag"
  assert_yaml_unchanged
}

@test "ctrl tag rejects a hostile service name" {
  run_ctrl set tag 'api") | .x = ("y' v2
  assert_failure
  assert_yaml_unchanged
}

@test "ctrl default rejects a hostile name" {
  run_ctrl set default 'prod" | .meta.project = "owned'
  assert_failure
  assert_yaml_unchanged
}

@test "ctrl run new-script rejects a hostile script name" {
  run_ctrl run new-script 'x$(touch ${PWNED})'
  assert_failure
  assert_contains "Invalid script name"
  assert_not_pwned
  assert_yaml_unchanged
}

# ── resolvers ───────────────────────────────────────────────────────────────

@test "hostile deployment name is rejected before any SSH is built" {
  run_ctrl -n deploy 'prod";touch ${PWNED};"' api
  assert_failure
  assert_not_pwned
}

@test "hostile service name is rejected by the service resolver" {
  run_ctrl -n build 'api$(touch ${PWNED})'
  assert_failure
  assert_not_pwned
}

@test "hostile machine name via CTRL_MACHINE is rejected" {
  CTRL_MACHINE='testbox";touch x;"' run_ctrl -n ssh
  assert_failure
  assert_contains "Invalid machine name"
}

@test "hostile compose_service in ctrl.yaml is rejected before deploy" {
  yq -i '.services[0].deploy.compose_service = "api; touch /tmp/x"' "${TEST_TMP}/ctrl.yaml"
  run_ctrl -n deploy prod api
  assert_failure
  assert_contains "Invalid compose service name"
}

@test "machine lookup with a name containing a quote finds nothing (no yq error leak)" {
  source_libs core.sh
  CTRL_YAML="$(cat "${TEST_TMP}/ctrl.yaml")"
  run is_machine 'testbox" or "1" == "1'
  assert_failure
}

# ── sniff / hc ─────────────────────────────────────────────────────────────

@test "sniff rejects a non-integer duration" {
  # sniff's pre-flight needs docker; fake it so the test runs where docker isn't installed
  mkdir -p "${TEST_TMP}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TEST_TMP}/bin/docker"; chmod +x "${TEST_TMP}/bin/docker"
  PATH="${TEST_TMP}/bin:${PATH}" run_ctrl run sniff api --duration '5; touch ${PWNED}' -n
  assert_failure
  assert_contains "--duration must be a whole number"
  assert_not_pwned
}

@test "hc rejects a non-integer --count" {
  run_ctrl hc api --count '3;id'
  assert_failure
  assert_contains "--count must be a positive whole number"
}

# ── MCP ─────────────────────────────────────────────────────────────────────

@test "MCP tool call with a hostile service returns an error instead of running" {
  source_libs core.sh services.sh deploy.sh remote.sh health.sh audit.sh ext.sh info.sh check.sh mcp.sh
  CTRL_CONFIG_FILE="${TEST_TMP}/ctrl.yaml"
  CTRL_YAML="$(cat "${CTRL_CONFIG_FILE}")"
  run _mcp_run_tool health_check '{"service":"api$(touch '"${PWNED}"')"}'
  assert_failure
  assert_contains "invalid service"
  assert_not_pwned
}

@test "MCP get_history rejects a non-integer count" {
  source_libs core.sh audit.sh info.sh mcp.sh
  CTRL_YAML="$(cat "${TEST_TMP}/ctrl.yaml")"
  run _mcp_run_tool get_history '{"count":"5; rm -rf ~"}'
  assert_failure
  assert_contains "count must be a whole number"
}

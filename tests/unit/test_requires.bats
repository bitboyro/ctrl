#!/usr/bin/env bats
# Unit tests for script requires blocks — _script_preflight_check catches
# missing tools and unset env vars before a script is executed.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

_write_noop_script() {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${TEST_TMP}/scripts/run.sh"
  chmod +x "${TEST_TMP}/scripts/run.sh"
}

setup() {
  setup_test_dir
  source_libs core.sh ext.sh
  write_fixture_yaml
  _write_noop_script
}

teardown() { teardown_test_dir; }

# ── requires.tools ────────────────────────────────────────────────────────────

@test "preflight passes when required tool exists" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"tools":["bash"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  load_config
  run _script_preflight_check run
  assert_success
}

@test "preflight fails when required tool is missing" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"tools":["__ctrl_no_such_tool_xyz__"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  load_config
  run _script_preflight_check run
  assert_failure
  assert_contains "__ctrl_no_such_tool_xyz__"
  assert_contains "not found"
}

@test "preflight fails listing all missing tools before stopping" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"tools":["__missing_a__","__missing_b__"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  load_config
  run _script_preflight_check run
  assert_failure
  assert_contains "__missing_a__"
  assert_contains "__missing_b__"
}

# ── requires.env ──────────────────────────────────────────────────────────────

@test "preflight passes when required env var is set" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"env":["MY_CTRL_TEST_VAR"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  load_config
  MY_CTRL_TEST_VAR=hello run _script_preflight_check run
  assert_success
}

@test "preflight fails when required env var is not set" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"env":["MY_CTRL_UNSET_VAR"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  load_config
  unset MY_CTRL_UNSET_VAR
  run _script_preflight_check run
  assert_failure
  assert_contains "MY_CTRL_UNSET_VAR"
  assert_contains "not set"
}

# ── requires not declared ─────────────────────────────────────────────────────

@test "preflight passes silently when script has no requires block" {
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh"}]' "${TEST_TMP}/ctrl.yaml"
  load_config
  run _script_preflight_check run
  assert_success
}

# ── ctrl run integration: preflight blocks execution ─────────────────────────

@test "ctrl run does not execute script when required tool is missing" {
  # Script writes a sentinel file if it actually runs
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${TEST_TMP}" > "${TEST_TMP}/scripts/run.sh"
  chmod +x "${TEST_TMP}/scripts/run.sh"
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"tools":["__ctrl_no_such_tool_xyz__"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl run run
  assert_failure
  [[ ! -f "${TEST_TMP}/ran" ]]
}

@test "ctrl run does not execute script when required env var is missing" {
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "${TEST_TMP}" > "${TEST_TMP}/scripts/run.sh"
  chmod +x "${TEST_TMP}/scripts/run.sh"
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"env":["MY_CTRL_UNSET_VAR"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  unset MY_CTRL_UNSET_VAR
  run_ctrl run run
  assert_failure
  [[ ! -f "${TEST_TMP}/ran" ]]
}

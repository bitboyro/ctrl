#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 5: Script Execution with Environment Context
# CR-4.1, CR-4.2, CR-4.5

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  mkdir -p "${TEST_TMP}/scripts"
  cat > "${TEST_TMP}/scripts/echoenv.sh" <<'SH'
#!/usr/bin/env bash
echo "CTRL_PROJECT=${CTRL_PROJECT}"
echo "CTRL_SSH_HOST=${CTRL_SSH_HOST}"
echo "CTRL_REGISTRY=${CTRL_REGISTRY}"
echo "CTRL_REMOTE_DIR=${CTRL_REMOTE_DIR}"
echo "CTRL_CONFIG_FILE=${CTRL_CONFIG_FILE}"
echo "CTRL_MACHINE_NAME=${CTRL_MACHINE_NAME}"
echo "CTRL_DEPLOY_NAME=${CTRL_DEPLOY_NAME}"
SH
  chmod +x "${TEST_TMP}/scripts/echoenv.sh"
  yq -i '.scripts = [{"name":"echoenv","path":"scripts/echoenv.sh"}]' "${TEST_TMP}/ctrl.yaml"
}

teardown() { teardown_test_dir; }

@test "ctrl run exposes all required env vars to the script" {
  run_ctrl run echoenv
  assert_success
  assert_contains "CTRL_PROJECT=test-project"
  assert_contains "CTRL_REGISTRY=docker.io/test"
  assert_contains "CTRL_CONFIG_FILE=${TEST_TMP}/ctrl.yaml"
  # SSH_HOST may be empty (no machine resolved) but variable must be present.
  assert_contains "CTRL_SSH_HOST="
  assert_contains "CTRL_MACHINE_NAME="
  assert_contains "CTRL_DEPLOY_NAME="
}

@test "ctrl run preserves script exit code" {
  cat > "${TEST_TMP}/scripts/bad.sh" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "${TEST_TMP}/scripts/bad.sh"
  yq -i '.scripts += [{"name":"bad","path":"scripts/bad.sh"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run bad
  assert_eq "${status}" "42"
}

@test "ctrl run fails with clear message when script not registered" {
  run_ctrl run does-not-exist
  assert_failure
  assert_contains "not found in ctrl.yaml"
}

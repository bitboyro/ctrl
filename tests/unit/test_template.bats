#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Properties 1 & 2: Script Template & Deployment Context

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
}

teardown() { teardown_test_dir; }

@test "ctrl script init generates a script with all required structural elements" {
  run_ctrl script init hello
  assert_success
  local script="${TEST_TMP}/scripts/hello.sh"
  [[ -f "${script}" ]]
  [[ -x "${script}" ]]
  local content; content="$(cat "${script}")"
  for needle in 'SCRIPT_DIR=' 'CTRL_ROOT=' '_check_deps' '_usage' '--help' '--dry-run' 'BASH_SOURCE[0]' 'trap _cleanup EXIT'; do
    echo "${content}" | grep -qF -- "${needle}" || { echo "missing: ${needle}"; return 1; }
  done
}

@test "generated script is registered in ctrl.yaml" {
  run_ctrl script init mythingy
  assert_success
  local found; found="$(yq '.scripts[] | select(.name == "mythingy") | .path' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${found}" "scripts/mythingy.sh"
}

@test "generated script --help exits 0 with usage output" {
  run_ctrl script init helper
  run bash "${TEST_TMP}/scripts/helper.sh" --help
  assert_success
  assert_contains "Usage:"
  assert_contains "--dry-run"
}

@test "deployment context detected when script lives under <deployment>/ops/" {
  mkdir -p "${TEST_TMP}/deployments/blue/ops"
  run_ctrl script init op1
  # Move the freshly created script into deployments/blue/ops/ and verify the
  # template's own context detection sets DEPLOYMENT_DIR and DEPLOYMENT_NAME.
  cp "${TEST_TMP}/scripts/op1.sh" "${TEST_TMP}/deployments/blue/ops/op1.sh"
  run bash -c "
    set -e
    source '${TEST_TMP}/deployments/blue/ops/op1.sh' 2>/dev/null || true
    echo \"DEPLOYMENT_DIR=\$DEPLOYMENT_DIR\"
    echo \"DEPLOYMENT_NAME=\$DEPLOYMENT_NAME\"
  "
  assert_contains "DEPLOYMENT_DIR=${TEST_TMP}/deployments/blue"
  assert_contains "DEPLOYMENT_NAME=blue"
}

@test "scripts NOT under ops/ have empty deployment context" {
  run_ctrl script init flatone
  run bash -c "
    source '${TEST_TMP}/scripts/flatone.sh' 2>/dev/null || true
    echo \"DEPLOYMENT_DIR=[\$DEPLOYMENT_DIR]\"
    echo \"DEPLOYMENT_NAME=[\$DEPLOYMENT_NAME]\"
  "
  assert_contains "DEPLOYMENT_DIR=[]"
  assert_contains "DEPLOYMENT_NAME=[]"
}

@test "template override at scripts/templates/ctrl-script.sh is used when present" {
  mkdir -p "${TEST_TMP}/scripts/templates"
  cat > "${TEST_TMP}/scripts/templates/ctrl-script.sh" <<'OVERRIDE'
#!/usr/bin/env bash
# OVERRIDE-TEMPLATE-MARKER for __NAME__
echo "override running: __NAME__"
OVERRIDE
  run_ctrl script init customone
  assert_success
  local content; content="$(cat "${TEST_TMP}/scripts/customone.sh")"
  echo "${content}" | grep -qF "OVERRIDE-TEMPLATE-MARKER for customone"
  echo "${content}" | grep -qF "override running: customone"
}

@test "empty template override falls back to built-in with warning" {
  mkdir -p "${TEST_TMP}/scripts/templates"
  : > "${TEST_TMP}/scripts/templates/ctrl-script.sh"   # empty
  run_ctrl script init fallback
  assert_success
  # Built-in template signature
  grep -qF "SCRIPT_DIR=" "${TEST_TMP}/scripts/fallback.sh"
  grep -qF "_check_deps" "${TEST_TMP}/scripts/fallback.sh"
}

@test "ctrl script init refuses to overwrite existing script" {
  run_ctrl script init dup
  assert_success
  run_ctrl script init dup
  assert_failure
  assert_contains "already exists"
}

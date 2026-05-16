#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 4: Version Mismatch Detection
# CR-3.3 — `ctrl check` warns on declared-vs-running version mismatch.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() { setup_test_dir; }
teardown() { teardown_test_dir; }

@test "no warning when ctrl.version matches running version" {
  write_fixture_yaml   # uses VERSION file → match
  run_ctrl --json check
  assert_success
  refute_contains "Version mismatch"
}

@test "warning emitted when ctrl.version differs from running version" {
  FIXTURE_VERSION="9.9.9" write_fixture_yaml
  run_ctrl --json check
  assert_success    # mismatch is a warning, not an error
  assert_contains "Version mismatch"
  assert_contains "9.9.9"
  assert_contains "$(cat "${CTRL_REPO_ROOT}/VERSION")"
}

@test "missing ctrl.version is an error" {
  write_fixture_yaml
  yq -i 'del(.ctrl.version)' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "ctrl.version is missing"
}
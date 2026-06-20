#!/usr/bin/env bats
# Unit tests for ctrl_set_tag and ctrl_set_default — the yq in-place write path.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  yq -i '.services = [
    {"name":"api",    "image":"docker.io/t/api",    "tag":"v1.0.0"},
    {"name":"worker", "image":"docker.io/t/worker",  "tag":"v1.0.0"}
  ]' "${TEST_TMP}/ctrl.yaml"
  # Second machine and deployment for ctrl_set_default tests
  yq -i '.machines.hosts += [{"name":"staging-box","host":"10.0.0.2","user":"root","port":22}]' \
    "${TEST_TMP}/ctrl.yaml"
  yq -i '.deployments.targets += [{"name":"staging","machine":"staging-box","compose_path":"/opt/s/dc.yml"}]' \
    "${TEST_TMP}/ctrl.yaml"
}

teardown() { teardown_test_dir; }

# ── ctrl tag (ctrl_set_tag) ───────────────────────────────────────────────────

@test "ctrl tag mutates the correct service tag in ctrl.yaml" {
  run_ctrl tag api v2.5.0
  assert_success
  result="$(yq '.services[] | select(.name == "api") | .tag' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "v2.5.0"
}

@test "ctrl tag does not change other services" {
  run_ctrl tag api v2.5.0
  assert_success
  result="$(yq '.services[] | select(.name == "worker") | .tag' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "v1.0.0"
}

@test "ctrl tag errors on unknown service" {
  run_ctrl tag nosuchsvc v9.9.9
  assert_failure
  assert_contains "Unknown service"
}

@test "ctrl tag updates the same service twice independently" {
  run_ctrl tag api v2.0.0
  run_ctrl tag api v3.0.0
  result="$(yq '.services[] | select(.name == "api") | .tag' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "v3.0.0"
}

# ── ctrl default (ctrl_set_default) ──────────────────────────────────────────

@test "ctrl default sets deployments.default when given a deployment target name" {
  run_ctrl default staging
  assert_success
  result="$(yq '.deployments.default' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "staging"
}

@test "ctrl default sets machines.default when given a machine name" {
  run_ctrl default staging-box
  assert_success
  result="$(yq '.machines.default' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "staging-box"
}

@test "ctrl default errors on unknown name" {
  run_ctrl default ghost
  assert_failure
  assert_contains "Unknown machine or deployment"
}

@test "ctrl default prefers deployment over machine when names collide" {
  # Add a machine with the same name as a deployment target
  yq -i '.machines.hosts += [{"name":"staging","host":"10.0.0.3","user":"root","port":22}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl default staging
  assert_success
  result="$(yq '.deployments.default' "${TEST_TMP}/ctrl.yaml")"
  assert_eq "${result}" "staging"
}

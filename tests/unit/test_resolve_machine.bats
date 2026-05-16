#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 8: Machine Field Resolution
# CR-5.2, CR-5.3, CR-5.4 — host/user/port/key/password resolution + env override.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh
}

teardown() { teardown_test_dir; }

@test "resolves plain host/user/port" {
  FIXTURE_MACHINE_HOST="10.0.0.1" FIXTURE_MACHINE_USER="ops" FIXTURE_MACHINE_PORT=2222 write_fixture_yaml
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_SSH_HOST}" "10.0.0.1"
  assert_eq "${CTRL_META_SSH_USER}" "ops"
  assert_eq "${CTRL_META_SSH_PORT}" "2222"
  assert_eq "${CTRL_MACHINE_NAME}"  "testbox"
}

@test "resolves \${VAR} references in host and password fields" {
  export MY_HOST="env-host.example" MY_PWD="s3cret"
  FIXTURE_MACHINE_HOST="\${MY_HOST}" FIXTURE_MACHINE_PASSWORD="\${MY_PWD}" write_fixture_yaml
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_SSH_HOST}"     "env-host.example"
  assert_eq "${CTRL_META_SSH_PASSWORD}" "s3cret"
}

@test "exports CTRL_META_SSH_PASSWORD for child processes" {
  export MY_PWD="exported"
  FIXTURE_MACHINE_PASSWORD="\${MY_PWD}" write_fixture_yaml
  load_config
  resolve_machine ""
  result="$(bash -c 'echo $CTRL_META_SSH_PASSWORD')"
  assert_eq "${result}" "exported"
}

@test "CTRL_MACHINE env var overrides explicit name argument" {
  write_fixture_yaml
  load_config
  # Add a second machine via yq
  yq -i '.machines.hosts += [{"name":"box2","host":"10.0.0.2","user":"root","port":22}]' "${TEST_TMP}/ctrl.yaml"
  load_config
  CTRL_MACHINE=box2 resolve_machine "testbox"
  assert_eq "${CTRL_MACHINE_NAME}" "box2"
  assert_eq "${CTRL_META_SSH_HOST}" "10.0.0.2"
}

@test "fails when machine name is unknown" {
  write_fixture_yaml
  load_config
  run resolve_machine "nonexistent"
  [[ "${status}" -ne 0 ]]
  assert_contains "Machine 'nonexistent' not found"
}

@test "fails when no machine specified and no default set" {
  FIXTURE_EXTRA_YAML="" write_fixture_yaml
  yq -i 'del(.machines.default)' "${TEST_TMP}/ctrl.yaml"
  load_config
  run resolve_machine ""
  [[ "${status}" -ne 0 ]]
  assert_contains "No machine specified"
}

@test "empty password field leaves CTRL_META_SSH_PASSWORD empty" {
  write_fixture_yaml   # no password line
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_SSH_PASSWORD}" ""
}

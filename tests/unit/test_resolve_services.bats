#!/usr/bin/env bats
# Unit tests for ctrl_resolve_services — the central service name dispatcher.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh
  write_fixture_yaml
  # Add three named services
  yq -i '.services = [
    {"name":"api","image":"docker.io/test/api","tag":"v1"},
    {"name":"worker","image":"docker.io/test/worker","tag":"v2"},
    {"name":"grafana","kind":"external","image":"grafana/grafana","tag":"10.0"}
  ]' "${TEST_TMP}/ctrl.yaml"
  load_config
}

teardown() { teardown_test_dir; }

@test "resolves a single service name" {
  result="$(ctrl_resolve_services api)"
  assert_eq "${result}" "api"
}

@test "resolves 'all' to every service in declaration order" {
  result="$(ctrl_resolve_services all)"
  assert_eq "${result}" "api worker grafana"
}

@test "'ALL' is case-insensitive" {
  result="$(ctrl_resolve_services ALL)"
  assert_eq "${result}" "api worker grafana"
}

@test "resolves multiple names as separate arguments" {
  result="$(ctrl_resolve_services api worker)"
  assert_eq "${result}" "api worker"
}

@test "resolves comma-separated names in a single argument" {
  result="$(ctrl_resolve_services "api,worker")"
  assert_eq "${result}" "api worker"
}

@test "trims whitespace around names" {
  result="$(ctrl_resolve_services " api ")"
  assert_eq "${result}" "api"
}

@test "fails with clear message on unknown service name" {
  run ctrl_resolve_services nonexistent
  assert_failure
  assert_contains "Unknown service: nonexistent"
}

@test "fails with no arguments" {
  run ctrl_resolve_services
  assert_failure
  assert_contains "No services resolved"
}

@test "fails when one name in a list is unknown" {
  run ctrl_resolve_services api bogus
  assert_failure
  assert_contains "Unknown service: bogus"
}

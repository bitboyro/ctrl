#!/usr/bin/env bats
# Unit tests for _svc_ping_url (probe.sh) and ctrl_ping error handling.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh probe.sh
}

teardown() { teardown_test_dir; }

# ── _svc_ping_url ──────────────────────────────────────────────────────────

@test "_svc_ping_url returns health.url when set" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      url: https://example.com/health" write_fixture_yaml
  load_config
  result="$(_svc_ping_url api)"
  assert_eq "${result}" "https://example.com/health"
}

@test "_svc_ping_url builds localhost URL from health.port" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      port: 8080" write_fixture_yaml
  load_config
  result="$(_svc_ping_url api)"
  assert_eq "${result}" "http://localhost:8080/actuator/health"
}

@test "_svc_ping_url prefers health.url over health.port when both are set" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      url: https://explicit.example.com/up
      port: 8080" write_fixture_yaml
  load_config
  result="$(_svc_ping_url api)"
  assert_eq "${result}" "https://explicit.example.com/up"
}

@test "_svc_ping_url returns empty when service has no health config" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    image: docker.io/test/api" write_fixture_yaml
  load_config
  result="$(_svc_ping_url api)"
  assert_eq "${result}" ""
}

# ── ctrl_ping error cases ──────────────────────────────────────────────────

@test "ctrl_ping fails with clear message on unknown name" {
  write_fixture_yaml
  load_config
  run ctrl_ping "nonexistent-service"
  assert_failure
  assert_contains "Unknown service or machine"
  assert_contains "nonexistent-service"
}

@test "ctrl_ping fails when called with no arguments" {
  write_fixture_yaml
  load_config
  run ctrl_ping
  assert_failure
  assert_contains "Usage: ctrl ping"
}

@test "ctrl_ping fails when service has no health config" {
  FIXTURE_EXTRA_YAML="services:
  - name: bare
    image: docker.io/test/bare" write_fixture_yaml
  load_config
  run ctrl_ping "bare"
  assert_failure
  assert_contains "no health.port or health.url"
}

@test "ctrl_ping rejects unknown flags" {
  write_fixture_yaml
  load_config
  run ctrl_ping "--bogus-flag"
  assert_failure
  assert_contains "Unknown flag"
}

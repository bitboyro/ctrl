#!/usr/bin/env bats
# Unit tests for the health URL resolver and ctrl hc argument handling (was: ping).

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh deploy.sh health.sh
}

teardown() { teardown_test_dir; }

# ── _svc_health_url ──────────────────────────────────────────────────────────

@test "_svc_health_url returns health.url when set" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      url: https://example.com/health" write_fixture_yaml
  load_config
  result="$(_svc_health_url api)"
  assert_eq "${result}" "https://example.com/health"
}

@test "_svc_health_url builds localhost URL from health.port" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      port: 8080" write_fixture_yaml
  load_config
  result="$(_svc_health_url api)"
  assert_eq "${result}" "http://localhost:8080/actuator/health"
}

@test "_svc_health_url prefers health.url over health.port when both are set" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    health:
      url: https://explicit.example.com/up
      port: 8080" write_fixture_yaml
  load_config
  result="$(_svc_health_url api)"
  assert_eq "${result}" "https://explicit.example.com/up"
}

@test "_svc_health_url returns empty when service has no health config" {
  FIXTURE_EXTRA_YAML="services:
  - name: api
    image: docker.io/test/api" write_fixture_yaml
  load_config
  result="$(_svc_health_url api)"
  assert_eq "${result}" ""
}

# ── ctrl hc error cases ──────────────────────────────────────────────────

@test "ctrl_hc fails with clear message on unknown name" {
  write_fixture_yaml
  load_config
  run ctrl_hc "nonexistent-service"
  assert_failure
  assert_contains "Unknown service or machine"
  assert_contains "nonexistent-service"
}

@test "ctrl_hc with no arguments and no health config warns and succeeds" {
  write_fixture_yaml
  load_config
  run ctrl_hc
  assert_success
  assert_contains "No services with health"
}

@test "ctrl_hc skips a service without health config; --count fails it" {
  FIXTURE_EXTRA_YAML="services:
  - name: bare
    image: docker.io/test/bare" write_fixture_yaml
  load_config
  run ctrl_hc "bare"
  assert_success
  assert_contains "skipping"
  run ctrl_hc "bare" --count 2
  assert_failure
  assert_contains "no health.port or health.url"
}

@test "ctrl_hc rejects unknown flags" {
  write_fixture_yaml
  load_config
  run ctrl_hc "--bogus-flag"
  assert_failure
  assert_contains "Unknown flag"
}

@test "ctrl_hc checks a machine over TCP (dry-run)" {
  write_fixture_yaml
  load_config
  CTRL_DRY_RUN=1
  has_cmd() { return 0; }
  run ctrl_hc testbox --count 3
  assert_success
  assert_contains "nc -z 127.0.0.1 22"
}

#!/usr/bin/env bats
# Unit tests for health_check_service — curl is mocked via PATH injection.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

# Write a fake curl that returns a fixed HTTP status code stored in FAKE_CURL_CODE.
_write_fake_curl() {
  local code="${1:-200}"
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/curl" <<SCRIPT
#!/usr/bin/env bash
# Emit the code for -w '%{http_code}' calls; swallow everything else.
for arg in "\$@"; do
  if [[ "\${arg}" == '%{http_code}' || "\${arg}" == "'%{http_code}'" ]]; then
    printf '%s' "${code}"
    exit 0
  fi
done
exit 0
SCRIPT
  chmod +x "${TEST_TMP}/bin/curl"
  export PATH="${TEST_TMP}/bin:${PATH}"
}

setup() {
  setup_test_dir
  source_libs core.sh health.sh
  write_fixture_yaml
  yq -i '.services = [
    {"name":"api",     "image":"docker.io/t/api",     "tag":"v1", "health":{"port":8080}},
    {"name":"worker",  "image":"docker.io/t/worker",  "tag":"v1", "health":{"url":"http://localhost:9090/health"}},
    {"name":"sc-core", "kind":"library",               "image":"docker.io/t/sc-core", "tag":"v1"},
    {"name":"nohealth","image":"docker.io/t/nohealth", "tag":"v1"}
  ]' "${TEST_TMP}/ctrl.yaml"
  load_config
  unset CTRL_META_SSH_HOST  # force local (non-SSH) path
}

teardown() { teardown_test_dir; }

# ── URL resolution (_svc_health_url) ─────────────────────────────────────────

@test "_svc_health_url builds URL from health.port" {
  result="$(_svc_health_url api)"
  assert_eq "${result}" "http://localhost:8080/actuator/health"
}

@test "_svc_health_url uses health.url verbatim" {
  result="$(_svc_health_url worker)"
  assert_eq "${result}" "http://localhost:9090/health"
}

@test "_svc_health_url returns empty when no health config" {
  result="$(_svc_health_url nohealth)"
  assert_eq "${result}" ""
}

# ── health_check_service ──────────────────────────────────────────────────────

@test "health_check_service succeeds when curl returns 200" {
  _write_fake_curl 200
  run health_check_service api
  assert_success
  assert_contains "healthy"
}

@test "health_check_service fails when curl returns 503" {
  _write_fake_curl 503
  run health_check_service api
  assert_failure
  assert_contains "503"
}

@test "health_check_service fails when curl returns 000 (no connection)" {
  _write_fake_curl 000
  run health_check_service api
  assert_failure
  assert_contains "000"
}

@test "health_check_service skips library services" {
  _write_fake_curl 200
  run health_check_service sc-core
  assert_success
  assert_contains "library"
}

@test "health_check_service skips services with no health config" {
  _write_fake_curl 200
  run health_check_service nohealth
  assert_success
  assert_contains "skipping"
}

@test "health_check_service fails on unknown service" {
  run health_check_service nosuchsvc
  assert_failure
  assert_contains "Unknown service"
}

@test "health_check_service uses health.url when set" {
  _write_fake_curl 200
  run health_check_service worker
  assert_success
  assert_contains "healthy"
}

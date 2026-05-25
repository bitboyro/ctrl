#!/usr/bin/env bats
# Unit tests for doctor.sh — _doctor_best_install priority and env var scanning.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh doctor.sh
}

teardown() { teardown_test_dir; }

# ── _doctor_best_install ───────────────────────────────────────────────────

@test "_doctor_best_install picks pip when python3 is available" {
  has_cmd() { [[ "$1" == "python3" ]]; }
  result="$(_doctor_best_install "brew install mytool" "apt-get install mytool" "mytool" "https://example.com/mytool")"
  assert_eq "${result}" "pip install mytool"
}

@test "_doctor_best_install picks brew when brew is available (no python3)" {
  has_cmd() { [[ "$1" == "brew" ]]; }
  result="$(_doctor_best_install "brew install mytool" "apt-get install mytool" "mytool" "https://example.com/mytool")"
  assert_eq "${result}" "brew install mytool"
}

@test "_doctor_best_install picks apt-get when only apt-get is available" {
  has_cmd() { [[ "$1" == "apt-get" ]]; }
  result="$(_doctor_best_install "brew install mytool" "apt-get install mytool" "mytool" "https://example.com/mytool")"
  assert_eq "${result}" "sudo apt-get install mytool"
}

@test "_doctor_best_install falls back to curl when nothing else is available" {
  has_cmd() { return 1; }
  # Assign into output so assert_contains works
  output="$(_doctor_best_install "" "" "" "https://example.com/releases/latest/download/mytool")"
  assert_contains "curl -fsSL"
  assert_contains "mytool"
  assert_contains "chmod +x"
}

@test "_doctor_best_install returns empty when no hints are provided and no tools available" {
  has_cmd() { return 1; }
  result="$(_doctor_best_install "" "" "" "")"
  assert_eq "${result}" ""
}

@test "_doctor_best_install skips pip hint when pip_hint is empty (even if python3 exists)" {
  has_cmd() { [[ "$1" == "python3" || "$1" == "brew" ]]; }
  result="$(_doctor_best_install "brew install mytool" "" "" "")"
  assert_eq "${result}" "brew install mytool"
}

# ── _doctor_check_env_vars ─────────────────────────────────────────────────

@test "_doctor_check_env_vars reports set vars as set" {
  export MY_CTRL_TEST_HOST="10.0.0.1"
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "${MY_CTRL_TEST_HOST}"
YAML
  CTRL_CONFIG_FILE="${TEST_TMP}/ctrl.yaml"
  source_libs core.sh doctor.sh
  local all_ok=1
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    export MY_CTRL_TEST_HOST=10.0.0.1
    _doctor_check_env_vars all_ok
  "
  assert_success
  assert_contains "MY_CTRL_TEST_HOST"
  assert_contains "set"
}

@test "_doctor_check_env_vars reports unset vars" {
  unset MY_CTRL_UNSET_VAR
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "${MY_CTRL_UNSET_VAR}"
YAML
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    unset MY_CTRL_UNSET_VAR
    all_ok=1
    _doctor_check_env_vars all_ok
  "
  assert_success
  assert_contains "MY_CTRL_UNSET_VAR"
  assert_contains "unset"
}

@test "_doctor_check_env_vars produces no env-var output when ctrl.yaml has no \${VAR} references" {
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "10.0.0.1"
YAML
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    all_ok=1
    _doctor_check_env_vars all_ok
  "
  # No env var scan lines should appear regardless of nameref support
  refute_contains "unset"
  refute_contains "VAR"
}

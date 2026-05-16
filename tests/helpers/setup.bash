#!/usr/bin/env bash
# tests/helpers/setup.bash — shared fixtures and assertions for ctrl tests.
# Source from each .bats file via:
#   load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

# Locate the ctrl repo root regardless of where tests run from.
CTRL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CTRL_REPO_ROOT

# Common scratch dir for one test. Cleaned in teardown_test_dir.
setup_test_dir() {
  TEST_TMP="$(mktemp -d -t ctrltest.XXXXXX)"
  export TEST_TMP
  export CTRL_CONFIG="${TEST_TMP}/ctrl.yaml"
  unset CTRL_MACHINE CTRL_DEPLOYMENT CTRL_DRY_RUN CTRL_VERBOSE CTRL_JSON
}

teardown_test_dir() {
  if [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]]; then
    rm -rf "${TEST_TMP}"
  fi
}

# Source one or more ctrl lib files into the current test shell.
# Usage: source_libs core.sh templates.sh
source_libs() {
  local lib
  for lib in "$@"; do
    # shellcheck disable=SC1090
    source "${CTRL_REPO_ROOT}/lib/${lib}"
  done
}

# Write a minimal valid ctrl.yaml into ${TEST_TMP}/ctrl.yaml.
# Optional kwargs (env vars): FIXTURE_VERSION, FIXTURE_PROJECT, FIXTURE_MACHINE_HOST,
# FIXTURE_MACHINE_USER, FIXTURE_MACHINE_PORT, FIXTURE_MACHINE_PASSWORD, FIXTURE_EXTRA_YAML.
write_fixture_yaml() {
  local version="${FIXTURE_VERSION:-$(cat "${CTRL_REPO_ROOT}/VERSION")}"
  local project="${FIXTURE_PROJECT:-test-project}"
  local host="${FIXTURE_MACHINE_HOST:-127.0.0.1}"
  local user="${FIXTURE_MACHINE_USER:-root}"
  local port="${FIXTURE_MACHINE_PORT:-22}"
  local password_line=""
  [[ -n "${FIXTURE_MACHINE_PASSWORD:-}" ]] && password_line="      password: \"${FIXTURE_MACHINE_PASSWORD}\""
  cat > "${TEST_TMP}/ctrl.yaml" <<YAML
ctrl:
  version: "${version}"
meta:
  project: ${project}
  registry: docker.io/test
machines:
  default: testbox
  hosts:
    - name: testbox
      host: "${host}"
      user: ${user}
      port: ${port}
${password_line}
services: []
deployments:
  default: prod
  targets:
    - name: prod
      machine: testbox
      compose_path: /opt/test/docker-compose.yml
scripts: []
extensions: []
${FIXTURE_EXTRA_YAML:-}
YAML
}

# Run the installed ctrl.sh from the repo against the current fixture.
# Captures status/output/lines per bats convention.
run_ctrl() {
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${CTRL_REPO_ROOT}/ctrl.sh" "$@"
}

# Assertion helpers ----------------------------------------------------------

assert_contains() {
  local needle="$1"
  if ! echo "${output}" | grep -qF -- "${needle}"; then
    echo "expected output to contain: ${needle}"
    echo "actual output:"
    echo "${output}"
    return 1
  fi
}

refute_contains() {
  local needle="$1"
  if echo "${output}" | grep -qF -- "${needle}"; then
    echo "expected output NOT to contain: ${needle}"
    echo "actual output:"
    echo "${output}"
    return 1
  fi
}

assert_success() {
  if [[ "${status}" -ne 0 ]]; then
    echo "expected status 0, got ${status}"
    echo "output: ${output}"
    return 1
  fi
}

assert_failure() {
  if [[ "${status}" -eq 0 ]]; then
    echo "expected non-zero status, got ${status}"
    echo "output: ${output}"
    return 1
  fi
}

assert_eq() {
  local actual="$1" expected="$2"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "expected: ${expected}"
    echo "actual:   ${actual}"
    return 1
  fi
}

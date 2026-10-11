#!/usr/bin/env bats
# Integration test for ctrl_ssh_run against a real sshd. Requires:
#   - sshpass installed
#   - an sshd reachable at $TEST_SSH_HOST:$TEST_SSH_PORT
#     with $TEST_SSH_USER / $TEST_SSH_PASSWORD credentials.
# In CI this is provided by a linuxserver/openssh-server service container.
# Locally, run a container yourself before invoking the test (see tests/README.md).

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

TEST_SSH_HOST="${TEST_SSH_HOST:-127.0.0.1}"
TEST_SSH_PORT="${TEST_SSH_PORT:-2222}"
TEST_SSH_USER="${TEST_SSH_USER:-ctrltest}"
TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD:-ctrltest}"

_skip_if_no_sshd() {
  command -v sshpass >/dev/null 2>&1 || skip "sshpass not installed"
  sshpass -p "${TEST_SSH_PASSWORD}" ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=2 \
    -p "${TEST_SSH_PORT}" \
    "${TEST_SSH_USER}@${TEST_SSH_HOST}" true \
    >/dev/null 2>&1 || skip "no sshd reachable at ${TEST_SSH_HOST}:${TEST_SSH_PORT}"
}

setup() {
  _skip_if_no_sshd
  setup_test_dir
  export TEST_SSH_PASSWORD
  FIXTURE_MACHINE_HOST="${TEST_SSH_HOST}" \
  FIXTURE_MACHINE_USER="${TEST_SSH_USER}" \
  FIXTURE_MACHINE_PORT="${TEST_SSH_PORT}" \
  FIXTURE_MACHINE_PASSWORD="\${TEST_SSH_PASSWORD}" write_fixture_yaml
}
teardown() { teardown_test_dir; }

@test "ctrl ssh testbox -- 'echo hello' returns hello via password auth" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh testbox -- echo hello
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"hello"* ]] || return 1
}

@test "ctrl ssh fails cleanly when sshpass is missing" {
  if ! command -v sshpass >/dev/null 2>&1; then skip "sshpass already missing"; fi
  # Simulate missing sshpass without depending on its install location.
  run env CTRL_CONFIG="${CTRL_CONFIG}" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    CTRL_SSHPASS_CMD="${TEST_TMP}/missing-sshpass" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh testbox -- true
  [[ "${status}" -ne 0 ]] || return 1
  [[ "${output}" == *"sshpass required"* ]] || return 1
}

@test "password is not present in --dry-run output" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" TEST_SSH_PASSWORD="supersecret" \
    "${CTRL_REPO_ROOT}/ctrl.sh" --dry-run ssh testbox -- echo x
  [[ "${output}" != *"supersecret"* ]] || return 1
  [[ "${output}" == *"<redacted>"* ]] || return 1
}

# ── ctrl run --on over real SSH ─────────────────────────────────────────────

@test "ctrl run --on streams a project script with args and ctrl env to the host" {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\n# @requires: sh\necho "remote=${CTRL_REMOTE} machine=${CTRL_MACHINE_NAME} args=$*"\n' > "${TEST_TMP}/scripts/where.sh"
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" run where --on testbox "a b" c
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"remote=1 machine=testbox args=a b c"* ]] || { echo "${output}"; return 1; }
}

@test "ctrl run --on stops at the remote pre-flight when a tool is missing" {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\n# @requires: __ctrl_not_on_remote__\necho BODY-RAN\n' > "${TEST_TMP}/scripts/needy.sh"
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" run needy --on testbox
  [[ "${status}" -ne 0 ]] || return 1
  [[ "${output}" == *"remote requires __ctrl_not_on_remote__"* ]] || { echo "${output}"; return 1; }
  [[ "${output}" != *"BODY-RAN"* ]] || return 1
}

@test "a bundled script runs on the host: sysinfo --short" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" run sysinfo --on testbox --short
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"cpu"*"mem"* ]] || { echo "${output}"; return 1; }
}

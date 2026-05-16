#!/usr/bin/env bats
# Integration test for ctrl_scp_send / ctrl sync against a real sshd.

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

  # Generate a fixture with a single deployment that syncs a local file.
  mkdir -p "${TEST_TMP}/payload"
  echo "hello-from-ctrl-test-$$" > "${TEST_TMP}/payload/file.txt"

  cat > "${TEST_TMP}/ctrl.yaml" <<YAML
ctrl:
  version: "$(cat "${CTRL_REPO_ROOT}/VERSION")"
meta:
  project: scp-test
  registry: docker.io/test
machines:
  default: testbox
  hosts:
    - name: testbox
      host: "${TEST_SSH_HOST}"
      user: ${TEST_SSH_USER}
      port: ${TEST_SSH_PORT}
      password: "\${TEST_SSH_PASSWORD}"
services: []
deployments:
  default: prod
  targets:
    - name: prod
      machine: testbox
      compose_path: /tmp/ctrl-scp-test/docker-compose.yml
      sync:
        paths:
          - payload/file.txt
scripts: []
extensions: []
YAML
}

teardown() {
  if [[ -n "${TEST_SSH_PASSWORD:-}" ]]; then
    sshpass -p "${TEST_SSH_PASSWORD}" ssh \
      -o StrictHostKeyChecking=accept-new \
      -p "${TEST_SSH_PORT}" \
      "${TEST_SSH_USER}@${TEST_SSH_HOST}" \
      "rm -rf /tmp/ctrl-scp-test" >/dev/null 2>&1 || true
  fi
  teardown_test_dir
}

@test "ctrl sync copies file to remote via password auth" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" sync prod
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }

  # Verify the file exists on the remote.
  run env CTRL_CONFIG="${CTRL_CONFIG}" TEST_SSH_PASSWORD="${TEST_SSH_PASSWORD}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh testbox -- cat /tmp/ctrl-scp-test/payload/file.txt
  [[ "${output}" == *"hello-from-ctrl-test-"* ]]
}

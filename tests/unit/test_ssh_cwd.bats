#!/usr/bin/env bats

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*"
EOF
  chmod +x "${TEST_TMP}/bin/ssh"
}

teardown() {
  teardown_test_dir
}

@test "ctrl ssh <machine> uses machines.hosts[].cwd when configured" {
  cat > "${CTRL_CONFIG}" <<'YAML'
ctrl:
  version: "0.1.1"
meta:
  project: test-project
  registry: docker.io/test
machines:
  default: testbox
  hosts:
    - name: testbox
      host: example.test
      user: ctrltest
      port: 2222
      cwd: /root
services: []
deployments:
  default: prod
  targets:
    - name: prod
      machine: testbox
      compose_path: /srv/app/docker-compose.yml
scripts: []
extensions: []
YAML

  run env PATH="${TEST_TMP}/bin:${PATH}" CTRL_CONFIG="${CTRL_CONFIG}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh testbox
  assert_success
  assert_contains "cd /root && exec"
}

@test "ctrl ssh <deployment> uses deployments.targets[].cwd over machines.hosts[].cwd" {
  cat > "${CTRL_CONFIG}" <<'YAML'
ctrl:
  version: "0.1.1"
meta:
  project: test-project
  registry: docker.io/test
machines:
  default: testbox
  hosts:
    - name: testbox
      host: example.test
      user: ctrltest
      port: 2222
      cwd: /root
services: []
deployments:
  default: prod
  targets:
    - name: prod
      machine: testbox
      compose_path: /srv/app/docker-compose.yml
      cwd: /workspace
scripts: []
extensions: []
YAML

  run env PATH="${TEST_TMP}/bin:${PATH}" CTRL_CONFIG="${CTRL_CONFIG}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh prod
  assert_success
  assert_contains "cd /workspace && exec"
}

@test "ctrl ssh <deployment> falls back to dirname(compose_path) when no cwd is configured" {
  cat > "${CTRL_CONFIG}" <<'YAML'
ctrl:
  version: "0.1.1"
meta:
  project: test-project
  registry: docker.io/test
machines:
  default: testbox
  hosts:
    - name: testbox
      host: example.test
      user: ctrltest
      port: 2222
services: []
deployments:
  default: prod
  targets:
    - name: prod
      machine: testbox
      compose_path: /srv/app/docker-compose.yml
scripts: []
extensions: []
YAML

  run env PATH="${TEST_TMP}/bin:${PATH}" CTRL_CONFIG="${CTRL_CONFIG}" \
    "${CTRL_REPO_ROOT}/ctrl.sh" ssh prod
  assert_success
  assert_contains "cd /srv/app && exec"
}
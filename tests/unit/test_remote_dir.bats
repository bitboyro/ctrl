#!/usr/bin/env bats
# Feature: remote working directory resolution (0.2.5)
# Priority order: deployment.remote_dir > dirname(compose_path) > machine.remote_dir > $CTRL_META_REMOTE_DIR > /opt/app

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  unset CTRL_META_REMOTE_DIR
  source_libs core.sh deploy.sh
}

teardown() { teardown_test_dir; }

# ── machine.remote_dir ────────────────────────────────────────────────────────

@test "resolve_machine sets CTRL_META_REMOTE_DIR from machine.remote_dir" {
  write_fixture_yaml
  yq -i '.machines.hosts[0].remote_dir = "/srv/custom"' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/custom"
}

@test "resolve_machine resolves \${VAR} refs in machine.remote_dir" {
  export MY_REMOTE_DIR="/srv/env-resolved"
  write_fixture_yaml
  yq -i '.machines.hosts[0].remote_dir = "${MY_REMOTE_DIR}"' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/env-resolved"
}

@test "resolve_machine leaves CTRL_META_REMOTE_DIR unchanged when machine has no remote_dir" {
  write_fixture_yaml
  load_config
  CTRL_META_REMOTE_DIR="/already/set"
  resolve_machine ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/already/set"
}

# ── env var fallback ──────────────────────────────────────────────────────────

@test "CTRL_META_REMOTE_DIR env var is used as default when no remote_dir is configured" {
  # unset + set env var before re-sourcing so the :-/opt/app initialiser picks it up
  unset CTRL_META_REMOTE_DIR
  export CTRL_META_REMOTE_DIR="/opt/env-default"
  source_libs core.sh
  write_fixture_yaml
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/opt/env-default"
}

@test "CTRL_META_REMOTE_DIR defaults to /opt/app when neither env var nor remote_dir is set" {
  write_fixture_yaml
  load_config
  resolve_machine ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/opt/app"
}

# ── deployment: dirname(compose_path) ─────────────────────────────────────────

@test "resolve_deployment derives CTRL_META_REMOTE_DIR from dirname(compose_path)" {
  write_fixture_yaml
  load_config
  resolve_deployment ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/opt/test"
}

@test "resolve_deployment uses machine.remote_dir when deployment has no compose_path" {
  write_fixture_yaml
  yq -i '.machines.hosts[0].remote_dir = "/srv/machine"' "${TEST_TMP}/ctrl.yaml"
  yq -i 'del(.deployments.targets[0].compose_path)' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_deployment ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/machine"
}

# ── deployment.remote_dir (explicit override) ─────────────────────────────────

@test "resolve_deployment explicit remote_dir overrides dirname(compose_path)" {
  write_fixture_yaml
  yq -i '.deployments.targets[0].remote_dir = "/srv/explicit"' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_deployment ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/explicit"
}

@test "resolve_deployment explicit remote_dir overrides machine.remote_dir" {
  write_fixture_yaml
  yq -i '.machines.hosts[0].remote_dir = "/srv/machine"' "${TEST_TMP}/ctrl.yaml"
  yq -i '.deployments.targets[0].remote_dir = "/srv/deployment"' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_deployment ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/deployment"
}

@test "resolve_deployment resolves \${VAR} refs in deployment.remote_dir" {
  export MY_DEPLOY_DIR="/srv/deploy-env"
  write_fixture_yaml
  yq -i '.deployments.targets[0].remote_dir = "${MY_DEPLOY_DIR}"' "${TEST_TMP}/ctrl.yaml"
  load_config
  resolve_deployment ""
  assert_eq "${CTRL_META_REMOTE_DIR}" "/srv/deploy-env"
}

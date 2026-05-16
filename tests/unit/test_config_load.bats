#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 3: Configuration Override Merge
# Also exercises CR-2.1, CR-2.2 — .local/ctrl.local.yaml overrides and implicit secrets.env

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  source_libs core.sh
}

teardown() { teardown_test_dir; }

@test "_find_config walks up from a subdir to ctrl.yaml" {
  mkdir -p "${TEST_TMP}/a/b/c"
  cd "${TEST_TMP}/a/b/c"
  unset CTRL_CONFIG_FILE
  CTRL_CONFIG_FILE=""
  _find_config
  assert_eq "${CTRL_CONFIG_FILE}" "${TEST_TMP}/ctrl.yaml"
}

@test "load_config populates CTRL_META_PROJECT and CTRL_META_REGISTRY" {
  load_config
  assert_eq "${CTRL_META_PROJECT}" "test-project"
  assert_eq "${CTRL_META_REGISTRY}" "docker.io/test"
}

@test ".local/ctrl.local.yaml overrides keys from ctrl.yaml" {
  mkdir -p "${TEST_TMP}/.local"
  cat > "${TEST_TMP}/.local/ctrl.local.yaml" <<'YAML'
meta:
  project: overridden-project
YAML
  load_config
  assert_eq "${CTRL_META_PROJECT}" "overridden-project"
}

@test ".local/secrets.env is auto-sourced even when not in meta.env_files" {
  mkdir -p "${TEST_TMP}/.local"
  echo "SECRET_FROM_LOCAL=hello-secret" > "${TEST_TMP}/.local/secrets.env"
  unset SECRET_FROM_LOCAL
  load_config
  assert_eq "${SECRET_FROM_LOCAL}" "hello-secret"
}

@test "no .local/secrets.env is silently OK (not an error)" {
  load_config
  # Implicit: load_config succeeded; CTRL_META_PROJECT was set.
  assert_eq "${CTRL_META_PROJECT}" "test-project"
}

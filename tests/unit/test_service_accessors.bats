#!/usr/bin/env bats
# Unit tests for service YAML accessor layer:
# ctrl_service_field, ctrl_service_kind, ctrl_service_exists,
# ctrl_service_names, _assert_kind_allows

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh services.sh
  write_fixture_yaml
  yq -i '.services = [
    {"name":"api",     "kind":"service",  "image":"docker.io/t/api",     "tag":"v1"},
    {"name":"worker",  "kind":"service",  "image":"docker.io/t/worker",  "tag":"v2"},
    {"name":"sc-core", "kind":"library",  "image":"docker.io/t/sc-core", "tag":"v1"},
    {"name":"grafana", "kind":"external", "image":"grafana/grafana",      "tag":"10.0"}
  ]' "${TEST_TMP}/ctrl.yaml"
  load_config
}

teardown() { teardown_test_dir; }

# ── ctrl_service_exists ────────────────────────────────────────────────────────

@test "ctrl_service_exists returns true for a declared service" {
  ctrl_service_exists api
}

@test "ctrl_service_exists returns false for an unknown name" {
  run ctrl_service_exists unknown
  assert_failure
}

# ── ctrl_service_names ────────────────────────────────────────────────────────

@test "ctrl_service_names lists all service names in order" {
  result="$(ctrl_service_names | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "${result}" "api worker sc-core grafana"
}

# ── ctrl_service_field ────────────────────────────────────────────────────────

@test "ctrl_service_field reads image" {
  result="$(ctrl_service_field api '.image // ""')"
  assert_eq "${result}" "docker.io/t/api"
}

@test "ctrl_service_field reads tag" {
  result="$(ctrl_service_field worker '.tag // "latest"')"
  assert_eq "${result}" "v2"
}

@test "ctrl_service_field returns default expression when field absent" {
  result="$(ctrl_service_field api '.build.tool // "maven"')"
  assert_eq "${result}" "maven"
}

@test "ctrl_service_field returns empty for a nonexistent service" {
  result="$(ctrl_service_field nosuchsvc '.image // ""')"
  assert_eq "${result}" ""
}

# ── ctrl_service_kind ─────────────────────────────────────────────────────────

@test "ctrl_service_kind returns declared kind" {
  assert_eq "$(ctrl_service_kind api)"     "service"
  assert_eq "$(ctrl_service_kind sc-core)" "library"
  assert_eq "$(ctrl_service_kind grafana)" "external"
}

@test "ctrl_service_kind defaults to 'service' when kind is absent" {
  yq -i '.services += [{"name":"implicit","image":"docker.io/t/implicit","tag":"v1"}]' "${TEST_TMP}/ctrl.yaml"
  load_config
  assert_eq "$(ctrl_service_kind implicit)" "service"
}

# ── _assert_kind_allows ───────────────────────────────────────────────────────

@test "_assert_kind_allows build succeeds for kind:service" {
  _assert_kind_allows api build
}

@test "_assert_kind_allows build fails for kind:external" {
  run _assert_kind_allows grafana build
  assert_failure
  assert_contains "kind: external"
}

@test "_assert_kind_allows image fails for kind:library" {
  run _assert_kind_allows sc-core image
  assert_failure
  assert_contains "kind: library"
}

@test "_assert_kind_allows image fails for kind:external" {
  run _assert_kind_allows grafana image
  assert_failure
  assert_contains "kind: external"
}

@test "_assert_kind_allows push fails for kind:library" {
  run _assert_kind_allows sc-core push
  assert_failure
  assert_contains "kind: library"
}

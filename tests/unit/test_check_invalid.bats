#!/usr/bin/env bats
# Unit tests for ctrl check with invalid ctrl.yaml fixtures.
# Covers errors and warnings that the happy-path smoke test never exercises.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
}

teardown() { teardown_test_dir; }

# ── machines ──────────────────────────────────────────────────────────────────

@test "check errors when machines.default points to an unknown host" {
  yq -i '.machines.default = "ghost"' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "ghost"
  assert_contains "not found in machines.hosts"
}

@test "check errors when a machine host has no host field" {
  yq -i '.machines.hosts += [{"name":"nohost","user":"root"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "nohost"
  assert_contains "has no host"
}

# ── deployments ───────────────────────────────────────────────────────────────

@test "check errors when deployments.default points to an unknown target" {
  yq -i '.deployments.default = "ghost"' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "ghost"
  assert_contains "not found in deployments.targets"
}

@test "check errors when a deployment references an unknown machine" {
  yq -i '.deployments.targets += [{"name":"staging","machine":"ghost-machine","compose_path":"/opt/s/dc.yml"}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "ghost-machine"
  assert_contains "unknown machine"
}

# ── services ──────────────────────────────────────────────────────────────────

@test "check errors on unknown service kind" {
  yq -i '.services = [{"name":"api","kind":"widget","image":"docker.io/t/api","tag":"v1"}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "unknown kind 'widget'"
}

@test "check warns when a service has no image" {
  yq -i '.services = [{"name":"api","tag":"v1"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "no image defined"
}

@test "check errors when a service smoke_test is not in scripts" {
  yq -i '.services = [{"name":"api","image":"docker.io/t/api","tag":"v1","smoke_tests":["smoke-missing"]}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "smoke-missing"
  assert_contains "not found in scripts"
}

# ── scripts ───────────────────────────────────────────────────────────────────

@test "check errors when a script has no path" {
  yq -i '.scripts = [{"name":"no-path"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "missing path"
}

@test "check warns when a script path does not exist on disk" {
  yq -i '.scripts = [{"name":"ghost","path":"scripts/ghost.sh"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "ghost.sh"
  assert_contains "not found"
}

@test "check errors on invalid requires.env entry (not a valid var name)" {
  mkdir -p "${TEST_TMP}/scripts"
  touch "${TEST_TMP}/scripts/run.sh"
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"env":["123BAD"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "123BAD"
  assert_contains "not a valid variable name"
}

@test "check warns on requires.tools entry containing whitespace" {
  mkdir -p "${TEST_TMP}/scripts"
  touch "${TEST_TMP}/scripts/run.sh"
  yq -i '.scripts = [{"name":"run","path":"scripts/run.sh","requires":{"tools":["bad tool"]}}]' \
    "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "bad tool"
  assert_contains "whitespace"
}

# ── meta ──────────────────────────────────────────────────────────────────────

@test "check errors when meta.project is missing" {
  yq -i 'del(.meta.project)' "${TEST_TMP}/ctrl.yaml"
  run_ctrl --json check
  assert_contains "meta.project is missing"
}

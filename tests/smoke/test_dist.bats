#!/usr/bin/env bats
# Smoke tests for the bundled dist/ctrl produced by build.sh.
# Verifies the bundling step doesn't break any user-facing surface.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

DIST_CTRL="${CTRL_REPO_ROOT}/dist/ctrl"

setup_file() {
  cd "${CTRL_REPO_ROOT}"
  bash build.sh >/dev/null
  [[ -x "${DIST_CTRL}" ]] || { echo "dist/ctrl not built"; return 1; }
}

setup() { setup_test_dir; }
teardown() { teardown_test_dir; }

@test "dist/ctrl version matches VERSION file" {
  run "${DIST_CTRL}" version
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "ctrl v$(cat "${CTRL_REPO_ROOT}/VERSION")" ]]
}

@test "dist/ctrl --help prints command list" {
  run "${DIST_CTRL}" --help
  [[ "${status}" -eq 0 ]]
  for cmd in build deploy ssh health-check run scripts init check machines mcp; do
    [[ "${output}" == *"${cmd}"* ]] || { echo "help missing: ${cmd}"; return 1; }
  done
}

@test "dist/ctrl check passes against a valid fixture" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" check
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
}

@test "dist/ctrl scripts --tag works against a fixture with tagged scripts" {
  write_fixture_yaml
  yq -i '.scripts = [
    {"name":"a","path":"scripts/a.sh","tags":["smoke"]},
    {"name":"b","path":"scripts/b.sh","tags":["deploy"]}
  ]' "${TEST_TMP}/ctrl.yaml"
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" scripts --tag smoke
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"a"* ]]
  [[ "${output}" != *"  b "* ]]
}

@test "dist/ctrl script init produces a runnable templated script" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" script init smokeone
  [[ "${status}" -eq 0 ]]
  [[ -x "${TEST_TMP}/scripts/smokeone.sh" ]]
  run bash "${TEST_TMP}/scripts/smokeone.sh" --help
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Usage:"* ]]
}

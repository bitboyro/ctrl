#!/usr/bin/env bats
# Smoke tests for the bundled dist/ctrl produced by build.sh.
# Verifies the bundling step doesn't break any user-facing surface.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

DIST_CTRL="${CTRL_REPO_ROOT}/dist/ctrl"

setup_file() {
  cd "${CTRL_REPO_ROOT}" || return 1
  bash build.sh >/dev/null
  [[ -x "${DIST_CTRL}" ]] || { echo "dist/ctrl not built"; return 1; }
}

setup() { setup_test_dir; }
teardown() { teardown_test_dir; }

@test "dist/ctrl version matches VERSION file" {
  run "${DIST_CTRL}" version
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == "ctrl v$(cat "${CTRL_REPO_ROOT}/VERSION")" ]] || return 1
}

@test "dist/ctrl --help prints command list" {
  run "${DIST_CTRL}" --help
  [[ "${status}" -eq 0 ]] || return 1
  for cmd in build deploy ssh hc run init check machines mcp doctor; do
    [[ "${output}" == *"${cmd}"* ]] || { echo "help missing: ${cmd}"; return 1; }
  done
}

@test "dist/ctrl check passes against a valid fixture" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" check
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
}

@test "dist/ctrl run --tag works against a fixture with tagged scripts" {
  write_fixture_yaml
  yq -i '.scripts = [
    {"name":"a","path":"scripts/a.sh","tags":["smoke"]},
    {"name":"b","path":"scripts/b.sh","tags":["deploy"]}
  ]' "${TEST_TMP}/ctrl.yaml"
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${DIST_CTRL}" run --tag smoke
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"a"* ]] || return 1
  [[ "${output}" != *"  b "* ]] || return 1
}

@test "dist/ctrl run new-script produces a runnable templated script" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${DIST_CTRL}" run new-script smokeone
  [[ "${status}" -eq 0 ]] || return 1
  [[ -x "${TEST_TMP}/scripts/smokeone.sh" ]] || return 1
  run bash "${TEST_TMP}/scripts/smokeone.sh" --help
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"Usage:"* ]] || return 1
}

@test "dist/ctrl completion bash exits 0 and contains _ctrl function" {
  run "${DIST_CTRL}" completion bash
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"_ctrl"* ]] || { echo "completion bash missing _ctrl"; return 1; }
  [[ "${output}" == *"complete"* ]] || { echo "completion bash missing complete call"; return 1; }
}

@test "dist/ctrl completion zsh exits 0 and contains compdef directive" {
  run "${DIST_CTRL}" completion zsh
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"#compdef ctrl"* ]] || { echo "completion zsh missing #compdef ctrl"; return 1; }
}

@test "dist/ctrl completion with unknown shell exits non-zero" {
  run "${DIST_CTRL}" completion fish
  [[ "${status}" -ne 0 ]] || return 1
}

@test "dist/ctrl doctor exits 0 against a valid fixture" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" doctor
  # doctor may report missing optional tools but should not crash
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"ctrl.yaml"* ]] || { echo "doctor missing ctrl.yaml check line"; return 1; }
}

@test "dist/ctrl help build prints build-specific help page" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" help build
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"build"* ]] || { echo "help build output missing 'build'"; return 1; }
  [[ "${output}" == *"Example"* ]] || { echo "help build output missing examples"; return 1; }
}

@test "dist/ctrl help deploy prints deploy-specific help page" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" help deploy
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"deploy"* ]] || { echo "help deploy output missing 'deploy'"; return 1; }
}

@test "dist/ctrl cp copies a local file" {
  write_fixture_yaml
  echo "hello" > "${TEST_TMP}/src.txt"
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" cp "${TEST_TMP}/src.txt" "${TEST_TMP}/dst.txt"
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ -f "${TEST_TMP}/dst.txt" ]] || { echo "destination file missing"; return 1; }
  [[ "$(cat "${TEST_TMP}/dst.txt")" == "hello" ]] || return 1
}

@test "dist/ctrl deploy --release dry-run does not crash with top-level local error" {
  write_fixture_yaml
  mkdir -p "${TEST_TMP}/svc"
  cat > "${TEST_TMP}/svc/Dockerfile" <<'EOF'
FROM scratch
EOF
  yq -i '.services = [{"name":"api","image":"docker.io/test/api","tag":"latest","build":{"tool":"skip","dir":"svc"}}]' "${TEST_TMP}/ctrl.yaml"

  run env CTRL_CONFIG="${CTRL_CONFIG}" DOCKERHUB_USERNAME=test DOCKERHUB_PASSWORD=test "${DIST_CTRL}" --dry-run deploy --release api
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ "${output}" != *"local: can only be used in a function"* ]] || { echo "unexpected top-level local error"; return 1; }
}

@test "dist/ctrl hc with unknown name exits non-zero with clear message" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" hc no-such-service
  [[ "${status}" -ne 0 ]] || return 1
  [[ "${output}" == *"Unknown service or machine"* ]] || { echo "hc error message missing"; return 1; }
}

@test "dist/ctrl run api-call with unknown service exits non-zero" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${DIST_CTRL}" run api-call no-such-service /health
  [[ "${status}" -ne 0 ]] || return 1
  [[ "${output}" == *"Unknown service"* ]] || { echo "api-call error message missing"; return 1; }
}

@test "dist/ctrl removed commands point at their replacement" {
  write_fixture_yaml
  run env CTRL_CONFIG="${CTRL_CONFIG}" "${DIST_CTRL}" probe no-such-target
  [[ "${status}" -ne 0 ]] || return 1
  [[ "${output}" == *"removed in ctrl 0.4"*"ctrl hc"* ]] || { echo "${output}"; return 1; }
}

@test "dist/ctrl lists and runs embedded bundled scripts outside a project" {
  cd "${TEST_TMP}"
  run env -u CTRL_CONFIG CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${DIST_CTRL}" run
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"new-script"* && "${output}" == *"sniff"* ]] || { echo "${output}"; return 1; }
  run env -u CTRL_CONFIG CTRL_CACHE_DIR="${TEST_TMP}/.cache" "${DIST_CTRL}" run new-script -n demo
  [[ "${status}" -eq 0 ]] || { echo "${output}"; return 1; }
}

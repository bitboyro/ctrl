#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 4: Version Mismatch Detection

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
load "${BATS_TEST_DIRNAME}/../helpers/random.bash"

setup() { setup_test_dir; }
teardown() { teardown_test_dir; }

@test "random version strings differing from VERSION always produce a mismatch warning" {
  local i declared running
  running="$(cat "${CTRL_REPO_ROOT}/VERSION")"
  for ((i = 0; i < PROPERTY_ITERATIONS; i++)); do
    declared="$(rand_version)"
    [[ "${declared}" == "${running}" ]] && continue   # accidentally equal — skip
    FIXTURE_VERSION="${declared}" write_fixture_yaml
    run_ctrl check
    [[ "${output}" == *"Version mismatch"* ]] || { echo "iter ${i}: declared=${declared} output=${output}"; return 1; }
    [[ "${output}" == *"${declared}"*       ]] || { echo "iter ${i}: missing declared version ${declared}"; return 1; }
    [[ "${output}" == *"${running}"*        ]] || { echo "iter ${i}: missing running version ${running}"; return 1; }
  done
}

@test "matching version never emits a mismatch warning" {
  local i running
  running="$(cat "${CTRL_REPO_ROOT}/VERSION")"
  for ((i = 0; i < 10; i++)); do
    FIXTURE_VERSION="${running}" write_fixture_yaml
    run_ctrl check
    [[ "${output}" != *"Version mismatch"* ]] || { echo "iter ${i}: unexpected mismatch ${output}"; return 1; }
  done
}

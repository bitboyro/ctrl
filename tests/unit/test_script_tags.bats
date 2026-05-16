#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 7: Script Tag Filtering — CR-4.4

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  FIXTURE_EXTRA_YAML="" write_fixture_yaml
  # Override scripts with a tagged set
  yq -i '.scripts = [
    {"name":"alpha","path":"scripts/alpha.sh","tags":["smoke","deploy"]},
    {"name":"bravo","path":"scripts/bravo.sh","tags":["deploy"]},
    {"name":"charlie","path":"scripts/charlie.sh","tags":["smoke"]},
    {"name":"delta","path":"scripts/delta.sh"}
  ]' "${TEST_TMP}/ctrl.yaml"
}

teardown() { teardown_test_dir; }

@test "no --tag lists all scripts" {
  run_ctrl scripts
  assert_success
  for n in alpha bravo charlie delta; do assert_contains "${n}"; done
}

@test "--tag deploy returns exactly the deploy-tagged scripts" {
  run_ctrl scripts --tag deploy
  assert_success
  assert_contains "alpha"
  assert_contains "bravo"
  refute_contains "charlie"
  refute_contains "delta"
}

@test "--tag smoke returns exactly the smoke-tagged scripts" {
  run_ctrl scripts --tag smoke
  assert_success
  assert_contains "alpha"
  assert_contains "charlie"
  refute_contains "bravo"
  refute_contains "delta"
}

@test "--tag with no matches returns no script rows" {
  run_ctrl scripts --tag nonexistent
  assert_success
  for n in alpha bravo charlie delta; do refute_contains "${n}"; done
}

#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 14: Environment Variable Reference Resolution

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
load "${BATS_TEST_DIRNAME}/../helpers/random.bash"

setup() {
  setup_test_dir
  source_libs core.sh
}
teardown() { teardown_test_dir; }

@test "random \${VAR} references resolve to their env values (100 iterations)" {
  local i name value result
  for ((i = 0; i < 100; i++)); do
    name="$(rand_env_name 10)"
    value="$(rand_env_value 16)"
    export "${name}=${value}"
    result="$(_resolve_env_refs "before-\${${name}}-after")"
    [[ "${result}" == "before-${value}-after" ]] || {
      echo "iter ${i}: name=${name} value=${value} result=${result}"; return 1; }
    unset "${name}"
  done
}

@test "random undefined \${VAR} references resolve to empty (no failure, 50 iterations)" {
  local i name result
  for ((i = 0; i < 50; i++)); do
    name="$(rand_env_name 12)"
    unset "${name}"
    result="$(_resolve_env_refs "x-\${${name}}-y")"
    [[ "${result}" == "x--y" ]] || { echo "iter ${i}: name=${name} result=${result}"; return 1; }
  done
}

#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 8: Machine Field Resolution

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
load "${BATS_TEST_DIRNAME}/../helpers/random.bash"

setup() {
  setup_test_dir
  source_libs core.sh
}
teardown() { teardown_test_dir; }

@test "random env-var refs in host/password resolve correctly (${PROPERTY_ITERATIONS} iterations)" {
  local i host_var host_val pwd_var pwd_val
  for ((i = 0; i < PROPERTY_ITERATIONS; i++)); do
    host_var="$(rand_env_name 8)"
    pwd_var="$(rand_env_name 8)"
    host_val="$(rand_env_value 16)"
    pwd_val="$(rand_env_value 24)"
    export "${host_var}=${host_val}" "${pwd_var}=${pwd_val}"
    FIXTURE_MACHINE_HOST="\${${host_var}}" FIXTURE_MACHINE_PASSWORD="\${${pwd_var}}" write_fixture_yaml
    load_config
    resolve_machine ""
    [[ "${CTRL_META_SSH_HOST}"     == "${host_val}" ]] || { echo "iter ${i}: host mismatch ${CTRL_META_SSH_HOST} != ${host_val}"; return 1; }
    [[ "${CTRL_META_SSH_PASSWORD}" == "${pwd_val}"  ]] || { echo "iter ${i}: pwd mismatch ${CTRL_META_SSH_PASSWORD} != ${pwd_val}"; return 1; }
    unset "${host_var}" "${pwd_var}"
  done
}

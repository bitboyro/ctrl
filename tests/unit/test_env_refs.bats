#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 14: Environment Variable Reference Resolution

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh
}

teardown() { teardown_test_dir; }

@test "resolves \${VAR} to current env value" {
  export TEST_VAR="resolved-value"
  result="$(_resolve_env_refs "before \${TEST_VAR} after")"
  assert_eq "${result}" "before resolved-value after"
}

@test "unresolved \${VAR} resolves to empty string without failure" {
  unset UNDEFINED_VAR
  result="$(_resolve_env_refs "before \${UNDEFINED_VAR} after")"
  assert_eq "${result}" "before  after"
}

@test "string without references is passed through unchanged" {
  result="$(_resolve_env_refs "literal value")"
  assert_eq "${result}" "literal value"
}

@test "multiple \${VAR} references resolve independently" {
  export A=foo B=bar
  result="$(_resolve_env_refs "\${A}-\${B}-\${A}")"
  assert_eq "${result}" "foo-bar-foo"
}

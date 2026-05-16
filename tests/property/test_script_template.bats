#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Properties 1 & 2: Template Structural Completeness + Deployment Context

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
load "${BATS_TEST_DIRNAME}/../helpers/random.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
}
teardown() { teardown_test_dir; }

@test "random script names always produce structurally complete templates (${PROPERTY_ITERATIONS} iterations)" {
  local i name script registered
  for ((i = 0; i < PROPERTY_ITERATIONS; i++)); do
    name="$(rand_script_name)-${i}"
    run_ctrl script init "${name}"
    [[ "${status}" -eq 0 ]] || { echo "iter ${i}: status=${status} output=${output}"; return 1; }
    script="${TEST_TMP}/scripts/${name}.sh"
    [[ -x "${script}" ]] || { echo "iter ${i}: not executable"; return 1; }
    for needle in 'SCRIPT_DIR=' 'CTRL_ROOT=' '_check_deps' '_usage' '--help' '--dry-run' 'BASH_SOURCE[0]' 'trap _cleanup EXIT'; do
      grep -qF -- "${needle}" "${script}" || { echo "iter ${i}: missing ${needle}"; return 1; }
    done
    registered="$(yq ".scripts[] | select(.name == \"${name}\") | .path" "${TEST_TMP}/ctrl.yaml")"
    [[ "${registered}" == "scripts/${name}.sh" ]] || { echo "iter ${i}: not registered (got ${registered})"; return 1; }
  done
}

@test "scripts under random <deployment>/ops/ paths detect their deployment context" {
  local i deploy_name script_path
  for ((i = 0; i < 10; i++)); do
    deploy_name="$(rand_word 6)-${i}"
    mkdir -p "${TEST_TMP}/deployments/${deploy_name}/ops"
    run_ctrl script init "tmpl${i}"
    script_path="${TEST_TMP}/deployments/${deploy_name}/ops/run.sh"
    cp "${TEST_TMP}/scripts/tmpl${i}.sh" "${script_path}"
    run bash -c "
      source '${script_path}' 2>/dev/null || true
      echo \"DEPLOYMENT_NAME=\$DEPLOYMENT_NAME\"
    "
    [[ "${output}" == *"DEPLOYMENT_NAME=${deploy_name}"* ]] || { echo "iter ${i}: ${output}"; return 1; }
  done
}

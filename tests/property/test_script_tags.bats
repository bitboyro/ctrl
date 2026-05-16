#!/usr/bin/env bats
# Feature: ctrl-devkit-integration, Property 7: Script Tag Filtering

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
load "${BATS_TEST_DIRNAME}/../helpers/random.bash"

setup() { setup_test_dir; }
teardown() { teardown_test_dir; }

@test "filtering by a random tag returns exactly the matching set (${PROPERTY_ITERATIONS} iterations)" {
  local i j script_count target_tag expected_names
  for ((i = 0; i < PROPERTY_ITERATIONS; i++)); do
    write_fixture_yaml
    script_count=$(( (RANDOM % 6) + 3 ))
    expected_names=""
    target_tag="$(rand_tags 1 | head -1)"
    yq -i '.scripts = []' "${TEST_TMP}/ctrl.yaml"
    for ((j = 0; j < script_count; j++)); do
      local sname="s${i}-${j}"
      # 50% chance this script has the target tag
      local tags
      if (( RANDOM % 2 == 0 )); then
        tags="[\"${target_tag}\", \"$(rand_word 4)\"]"
        expected_names="${expected_names} ${sname}"
      else
        tags="[\"$(rand_word 4)\"]"
      fi
      yq -i ".scripts += [{\"name\":\"${sname}\",\"path\":\"scripts/${sname}.sh\",\"tags\":${tags}}]" "${TEST_TMP}/ctrl.yaml"
    done

    run_ctrl scripts --tag "${target_tag}"
    [[ "${status}" -eq 0 ]] || { echo "iter ${i}: status=${status}"; return 1; }

    # Every expected name should appear, no unexpected ones.
    local n
    for n in ${expected_names}; do
      [[ "${output}" == *"${n}"* ]] || { echo "iter ${i}: missing expected ${n} in:\n${output}"; return 1; }
    done
    for ((j = 0; j < script_count; j++)); do
      local sname="s${i}-${j}"
      if [[ " ${expected_names} " != *" ${sname} "* ]]; then
        [[ "${output}" != *"${sname}"* ]] || { echo "iter ${i}: unexpected ${sname} in:\n${output}"; return 1; }
      fi
    done
  done
}

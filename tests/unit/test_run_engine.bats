#!/usr/bin/env bats
# Unit tests for the ctrl run engine (lib/scripts.sh): header metadata,
# resolution order, listing, --show / --own / --check, dry-run, sudo gate.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  mkdir -p "${TEST_TMP}/scripts"
}

teardown() { teardown_test_dir; }

_write_script() {
  local name="$1"; shift
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "${TEST_TMP}/scripts/${name}.sh"
  chmod +x "${TEST_TMP}/scripts/${name}.sh"
}

# ── headers ─────────────────────────────────────────────────────────────────

@test "header keys are parsed, lists normalised to spaces" {
  source_libs core.sh scripts.sh
  _write_script hdr '# @description: Does a thing' '# @requires: jq, curl' '# @os: linux darwin' '# @sudo: yes'
  assert_eq "$(_script_header "${TEST_TMP}/scripts/hdr.sh" description)" "Does a thing"
  assert_eq "$(_script_header "${TEST_TMP}/scripts/hdr.sh" requires)" "jq  curl"
  assert_eq "$(_script_header "${TEST_TMP}/scripts/hdr.sh" os)" "linux darwin"
  assert_eq "$(_script_header "${TEST_TMP}/scripts/hdr.sh" missing)" ""
}

@test "headers after line 60 are ignored" {
  source_libs core.sh scripts.sh
  { printf '#!/usr/bin/env bash\n'; for i in $(seq 1 65); do echo "# filler"; done; echo "# @description: too late"; } > "${TEST_TMP}/scripts/late.sh"
  assert_eq "$(_script_header "${TEST_TMP}/scripts/late.sh" description)" ""
}

@test "ctrl.yaml entry overrides header metadata" {
  _write_script ov '# @description: from header' '# @requires: bash'
  yq -i '.scripts = [{"name":"ov","description":"from yaml","requires":{"tools":["__nope__"]}}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run ov --show
  assert_success
  assert_contains "from yaml"
  assert_contains "__nope__"
  run_ctrl run ov
  assert_failure
  assert_contains "__nope__"
}

@test "header @requires blocks execution when the tool is missing, with the reason" {
  _write_script needs '# @requires: __ctrl_missing_tool__' 'touch "${CTRL_PROJECT_DIR}/ran"'
  run_ctrl run needs
  assert_failure
  assert_contains "requires tool '__ctrl_missing_tool__'"
  [[ ! -f "${TEST_TMP}/ran" ]] || return 1
}

@test "header @os refuses to run on another OS" {
  _write_script linuxonly '# @os: __otheros__' 'touch "${CTRL_PROJECT_DIR}/ran"'
  run_ctrl run linuxonly
  assert_failure
  assert_contains "supports: __otheros__"
  [[ ! -f "${TEST_TMP}/ran" ]] || return 1
}

@test "missing tool in the registry prints a platform install hint" {
  yq -i '.meta.tools = [{"name":"__ctrl_fake_tool__","install":{"apt":"fake-pkg","brew":"fake-formula"}}]' "${TEST_TMP}/ctrl.yaml"
  _write_script usesfake '# @requires: __ctrl_fake_tool__'
  CTRL_OS=linux CTRL_PKG=apt run_ctrl run usesfake
  assert_failure
  assert_contains "apt-get install -y fake-pkg"
  CTRL_OS=darwin CTRL_PKG=brew run_ctrl run usesfake
  assert_contains "brew install fake-formula"
}

# ── resolution ──────────────────────────────────────────────────────────────

@test "scripts/<name>.sh is auto-discovered without a ctrl.yaml entry" {
  _write_script hello 'echo "hello from project"'
  run_ctrl run hello
  assert_success
  assert_contains "hello from project"
}

@test "bundled scripts run without any ctrl.yaml" {
  cd "${TEST_TMP}"
  rm ctrl.yaml
  run env -u CTRL_CONFIG CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" run new-script -n demo
  assert_success
  assert_contains "write "
}

@test "project copy beats the bundled script of the same name" {
  _write_script new-script 'echo "PROJECT COPY"'
  run_ctrl run new-script
  assert_success
  assert_contains "PROJECT COPY"
}

@test "yaml path entry beats scripts/<name>.sh" {
  _write_script dup 'echo "discovered"'
  mkdir -p "${TEST_TMP}/ops"
  printf '#!/usr/bin/env bash\necho "from yaml path"\n' > "${TEST_TMP}/ops/dup.sh"
  yq -i '.scripts = [{"name":"dup","path":"ops/dup.sh"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run dup
  assert_contains "from yaml path"
  refute_contains "discovered"
}

@test "unknown script lists where it looked" {
  run_ctrl run nope-nothing
  assert_failure
  assert_contains "not found in ctrl.yaml scripts:"
  assert_contains "bundled"
}

@test "arguments after the name reach the script, including ctrl-looking flags" {
  _write_script args 'printf "[%s]" "$@"; echo'
  run_ctrl run args one --json --follow "two words" -- -n
  assert_success
  assert_contains "[one][--json][--follow][two words][-n]"
}

# ── listing ─────────────────────────────────────────────────────────────────

@test "ctrl run lists yaml, discovered and bundled scripts with their source" {
  _write_script mine '# @description: my script'
  yq -i '.scripts = [{"name":"registered","path":"scripts/registered.sh","description":"reg"}]' "${TEST_TMP}/ctrl.yaml"
  _write_script registered
  run_ctrl run
  assert_success
  assert_contains "mine"
  assert_contains "registered"
  assert_contains "new-script"
  assert_contains "bundled"
}

@test "ctrl run --json returns structured rows" {
  _write_script mine '# @description: my script' '# @os: linux'
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" --json run
  assert_success
  echo "${output}" | jq -e '.[] | select(.name == "mine") | .source == "project" and .os == ["linux"] and .description == "my script"'
  echo "${output}" | jq -e '.[] | select(.name == "new-script") | .source == "bundled"'
}

@test "a project copy of a bundled script is marked as overriding it" {
  _write_script new-script 'echo mine'
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" --json run
  echo "${output}" | jq -e '.[] | select(.name == "new-script") | .source == "project" and .overrides_bundled == true'
}

# ── --show / --own ──────────────────────────────────────────────────────────

@test "--own copies a bundled script into scripts/ with helpers inlined" {
  run_ctrl run new-script --own
  assert_success
  [[ -x "${TEST_TMP}/scripts/new-script.sh" ]] || return 1
  grep -q 'common_flags()' "${TEST_TMP}/scripts/new-script.sh" || return 1
  if grep -q '^# ctrl:lib$' "${TEST_TMP}/scripts/new-script.sh"; then return 1; fi
}

@test "--own refuses when the project already owns the script" {
  run_ctrl run new-script --own
  run_ctrl run new-script --own
  assert_failure
  assert_contains "already owns"
}

@test "--own refuses a script that is not bundled" {
  _write_script local-only
  run_ctrl run local-only --own
  assert_failure
  assert_contains "not a bundled script"
}

@test "--show on an owned copy prints the diff against the bundled version" {
  run_ctrl run new-script --own
  echo '# my local change' >> "${TEST_TMP}/scripts/new-script.sh"
  run_ctrl run new-script --show
  assert_success
  assert_contains "diff bundled → project"
  assert_contains "+# my local change"
}

@test "the owned copy runs standalone, without ctrl" {
  run_ctrl run new-script --own
  cd "${TEST_TMP}"
  run env -i PATH="${PATH}" HOME="${HOME}" bash scripts/new-script.sh --help
  assert_success
  assert_contains "new-script"
}

# ── --check / dry-run / sudo ────────────────────────────────────────────────

@test "--check runs pre-flight only and does not execute the script" {
  _write_script chk '# @requires: bash' 'touch "${CTRL_PROJECT_DIR}/ran"'
  run_ctrl run chk --check
  assert_success
  assert_contains "pre-flight ok"
  [[ ! -f "${TEST_TMP}/ran" ]] || return 1
}

@test "dry-run does not execute a script that does not declare @dry-run" {
  _write_script plain 'touch "${CTRL_PROJECT_DIR}/ran"'
  run_ctrl run plain -n
  assert_success
  assert_contains "[DRY-RUN] script plain"
  [[ ! -f "${TEST_TMP}/ran" ]] || return 1
}

@test "dry-run executes an @dry-run script with CTRL_DRY_RUN=1" {
  _write_script dr '# @dry-run: yes' 'echo "dry=${CTRL_DRY_RUN}"'
  run_ctrl run dr -n
  assert_success
  assert_contains "dry=1"
}

@test "@sudo script refuses without --yes when not interactive" {
  _write_script root '# @sudo: yes' 'touch "${CTRL_PROJECT_DIR}/ran"'
  run_ctrl run root < /dev/null
  assert_failure
  assert_contains "--yes"
  [[ ! -f "${TEST_TMP}/ran" ]] || return 1
}

@test "@sudo script runs with --yes and sees CTRL_YES=1" {
  _write_script root '# @sudo: yes' 'echo "yes=${CTRL_YES}"'
  run_ctrl run root --yes < /dev/null
  assert_success
  assert_contains "yes=1"
}

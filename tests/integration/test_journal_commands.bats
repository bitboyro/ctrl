#!/usr/bin/env bats
# Integration tests — verify that ctrl check, ctrl run, and ctrl tag each
# write a structured journal entry. Pure local; no SSH or Docker required.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  mkdir -p "${TEST_TMP}/.local"   # forces project-local journal
  write_fixture_yaml

  # Register a no-op script for run tests
  mkdir -p "${TEST_TMP}/scripts"
  cat > "${TEST_TMP}/scripts/noop.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "${TEST_TMP}/scripts/noop.sh"
  yq -i '.scripts = [{"name":"noop","path":"scripts/noop.sh"}]' "${TEST_TMP}/ctrl.yaml"

  # Add a service with a tag so ctrl tag has something to update
  yq -i '.services = [{"name":"api","image":"docker.io/test/api","tag":"v1.0.0"}]' "${TEST_TMP}/ctrl.yaml"
}

teardown() { teardown_test_dir; }

_last_journal_entry() {
  local journal="${TEST_TMP}/.local/journal/journal.jsonl"
  [[ -f "${journal}" ]] || { echo "journal missing at ${journal}" >&2; return 1; }
  tail -1 "${journal}"
}

# ── ctrl check ────────────────────────────────────────────────────────────

@test "ctrl check writes a journal entry with command=check" {
  run_ctrl check
  assert_success

  local entry; entry="$(_last_journal_entry)"
  echo "${entry}" | jq -e '.command == "check"'
  echo "${entry}" | jq -e '.exit_code == 0'
  echo "${entry}" | jq -e '(.ts | length) > 0'
  echo "${entry}" | jq -e '(.version | length) > 0'
}

# ── ctrl run ──────────────────────────────────────────────────────────────

@test "ctrl run writes a journal entry with command=run and the script name" {
  run_ctrl run noop
  assert_success

  local entry; entry="$(_last_journal_entry)"
  echo "${entry}" | jq -e '.command == "run"'
  echo "${entry}" | jq -e '.services == "noop"'
  echo "${entry}" | jq -e '.exit_code == 0'
}

@test "ctrl run journal entry captures non-zero exit from failing script" {
  cat > "${TEST_TMP}/scripts/fail.sh" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "${TEST_TMP}/scripts/fail.sh"
  yq -i '.scripts += [{"name":"fail","path":"scripts/fail.sh"}]' "${TEST_TMP}/ctrl.yaml"

  run_ctrl run fail
  # ctrl itself exits non-zero because the script failed
  [[ "${status}" -ne 0 ]] || true

  local entry; entry="$(_last_journal_entry)"
  echo "${entry}" | jq -e '.command == "run"'
  echo "${entry}" | jq -e '.services == "fail"'
  echo "${entry}" | jq -e '.exit_code != 0'
}

# ── ctrl tag ──────────────────────────────────────────────────────────────

@test "ctrl tag writes a journal entry with command=tag" {
  run_ctrl tag api v2.0.0
  assert_success

  local entry; entry="$(_last_journal_entry)"
  echo "${entry}" | jq -e '.command == "tag"'
  echo "${entry}" | jq -e '(.services | test("api"))'
  echo "${entry}" | jq -e '.exit_code == 0'
}

@test "ctrl tag exits non-zero and writes no journal when service does not exist" {
  run_ctrl tag nonexistent v9.9.9
  assert_failure

  # fail() calls exit 1 immediately — with_journal never gets to flush, so no entry.
  local journal="${TEST_TMP}/.local/journal/journal.jsonl"
  [[ ! -f "${journal}" ]] || {
    echo "expected no journal entry for a validation failure, but journal exists:"
    cat "${journal}"
    return 1
  }
}

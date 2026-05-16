#!/usr/bin/env bats
# CR-2.3 — Journal lives at <project>/.local/journal/ when .local/ exists, else ~/.local/share/ctrl/.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() { setup_test_dir; write_fixture_yaml; }
teardown() { teardown_test_dir; }

@test "journal points at .local/journal when .local/ exists" {
  mkdir -p "${TEST_TMP}/.local"
  source_libs core.sh
  load_config
  assert_eq "${CTRL_JOURNAL_DIR}" "${TEST_TMP}/.local/journal"
  assert_eq "${CTRL_JOURNAL}"     "${TEST_TMP}/.local/journal/journal.jsonl"
}

@test "journal falls back to \$HOME/.local/share/ctrl when no project .local/" {
  source_libs core.sh
  load_config
  assert_eq "${CTRL_JOURNAL_DIR}" "${HOME}/.local/share/ctrl"
  assert_eq "${CTRL_JOURNAL}"     "${HOME}/.local/share/ctrl/journal.jsonl"
}

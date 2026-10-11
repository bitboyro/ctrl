#!/usr/bin/env bats
# Tests for the dev scripts: lint (fake linters on PATH), loc (exact counts on a
# fixture tree) and churn (a throwaway git repo with two authors).

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  export W="${TEST_TMP}/work"
  mkdir -p "${W}" "${TEST_TMP}/bin"
  export PATH="${TEST_TMP}/bin:${PATH}"
  cd "${W}" || return 1
}

teardown() { teardown_test_dir; }

_ctrl_here() { run env -u CTRL_CONFIG CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" "$@"; }

_fake() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${TEST_TMP}/bin/$1"; chmod +x "${TEST_TMP}/bin/$1"; }

_git_init() {
  git init -q .
  git config user.email a@example.com
  git config user.name "Alice"
  git config commit.gpgsign false
}

# ── loc ─────────────────────────────────────────────────────────────────────

_loc_fixture() {
  mkdir -p src docs
  printf '#!/usr/bin/env bash\n# a comment\n\necho one\necho two\n' > src/a.sh     # code 3 (shebang counts), comment 1, blank 1
  printf '# c\nx = 1\n\n' > src/b.py                                            # code 1, comment 1, blank 1
  printf '// line\n/* block\n   still */\nfunc main() {}\n' > src/main.go        # code 1, comment 3
  printf '# Title\n\ntext\n' > docs/readme.md                                   # code 2, blank 1
  printf 'binary-ish\n' > src/LICENSE                                           # unknown: ignored
}

@test "loc counts code, comments and blanks per language exactly" {
  _loc_fixture
  _ctrl_here run loc --json
  assert_success
  local json; json="$(printf '%s\n' "${output}" | grep '^\[')"
  echo "${json}" | jq -e '.[] | select(.lang == "Shell")    | .files == 1 and .code == 3 and .comment == 1 and .blank == 1' >/dev/null
  echo "${json}" | jq -e '.[] | select(.lang == "Python")   | .code == 1 and .comment == 1 and .blank == 1' >/dev/null
  echo "${json}" | jq -e '.[] | select(.lang == "Go")       | .code == 1 and .comment == 3' >/dev/null
  echo "${json}" | jq -e '.[] | select(.lang == "Markdown") | .code == 2 and .blank == 1' >/dev/null
  echo "${json}" | jq -e 'length == 4' >/dev/null
}

@test "loc --by dir groups by top-level folder, --by file ranks files" {
  _loc_fixture
  _ctrl_here run loc --by dir --json
  printf '%s\n' "${output}" | grep '^\[' | jq -e '[.[].dir] | sort == ["docs/", "src/"]' >/dev/null
  _ctrl_here run loc --by file --top 1 --json
  printf '%s\n' "${output}" | grep '^\[' | jq -e 'length == 1 and .[0].file == "src/a.sh"' >/dev/null
}

@test "loc table shows a total and share bars" {
  _loc_fixture
  _ctrl_here run loc
  assert_success
  assert_contains "total"
  assert_contains "Shell"
  assert_contains "%"
}

@test "loc skips vendored and build folders outside git" {
  _loc_fixture
  mkdir -p node_modules/x build; printf 'echo x\n' > node_modules/x/y.sh; printf 'echo x\n' > build/z.sh
  _ctrl_here run loc --json
  printf '%s\n' "${output}" | grep '^\[' | jq -e '.[] | select(.lang == "Shell") | .files == 1' >/dev/null
}

@test "loc in a git repo counts tracked and untracked-but-not-ignored files" {
  _git_init
  _loc_fixture
  printf 'ignored.sh\n' > .gitignore; printf 'echo i\n' > ignored.sh
  git add src && git commit -qm init
  _ctrl_here run loc --json
  local json; json="$(printf '%s\n' "${output}" | grep '^\[')"
  echo "${json}" | jq -e '.[] | select(.lang == "Shell") | .files == 1' >/dev/null      # ignored.sh excluded
  echo "${json}" | jq -e '.[] | select(.lang == "Markdown") | .files == 1' >/dev/null   # untracked docs/ included
}

# ── churn ───────────────────────────────────────────────────────────────────

_churn_repo() {
  _git_init
  printf 'a\nb\nc\n' > hot.txt; printf 'x\n' > cold.txt
  git add . && git commit -qm one
  printf 'a\nb\nc\nd\n' > hot.txt; git commit -qam two
  git -c user.name="Bob" -c user.email=b@example.com commit -q --allow-empty -m empty
  printf 'z\n' >> hot.txt
  git -c user.name="Bob" -c user.email=b@example.com commit -qam three
}

@test "churn --by author counts commits and lines per author" {
  _churn_repo
  _ctrl_here run churn --since '1 day'
  assert_success
  assert_contains "Alice"
  assert_contains "Bob"
  assert_contains "4 commits"
}

@test "churn --by file ranks the most-changed file first" {
  _churn_repo
  _ctrl_here run churn --by file
  assert_success
  local first; first="$(printf '%s\n' "${output}" | grep -E '^(hot|cold)\.txt' | head -1)"
  [[ "${first}" == hot.txt* ]] || { echo "${output}"; return 1; }
}

@test "churn --by hotspot scores changes × current size" {
  _churn_repo
  _ctrl_here run churn --by hotspot
  assert_success
  # hot.txt: 3 changes × 5 lines = 15
  printf '%s\n' "${output}" | grep -qE '^hot\.txt +3 +5 +15' || { echo "${output}"; return 1; }
}

@test "churn outside git and with a bad --since fails clearly" {
  _ctrl_here run churn
  assert_failure
  assert_contains "Not a git repository"
  _churn_repo
  _ctrl_here run churn --since '$(id)'
  assert_failure
  assert_contains "--since must look like"
}

# ── lint ────────────────────────────────────────────────────────────────────

_lint_fixture() {
  mkdir -p .github/workflows
  printf '#!/usr/bin/env bash\necho ok\n' > good.sh
  printf '#!/usr/bin/env bash\n# BAD\n' > bad.sh
  printf '#!/bin/sh\necho no-extension\n' > tool
  printf 'a: 1\n' > conf.yaml
  printf '{"a": 1}\n' > data.json
  printf 'FROM scratch\n' > Dockerfile
  printf 'on: push\n' > .github/workflows/ci.yml
}

# fake shellcheck: fails on any file containing BAD, logs the files it saw
_fake_shellcheck() {
  _fake shellcheck 'shift 3; printf "%s\n" "$@" >> "'"${TEST_TMP}"'/shellcheck.args"; ! grep -l BAD "$@"'
}

@test "lint detects kinds and reports missing linters with an install hint" {
  _lint_fixture
  _fake_shellcheck
  _ctrl_here run lint --list
  assert_success
  assert_contains "shell       shellcheck         3  would run"
  assert_contains "json        jq (parse)         1  would run"
  assert_contains "dockerfile"
  assert_contains "actions"
  if ! command -v hadolint >/dev/null; then assert_contains "missing:"; fi
}

@test "lint fails when a linter fails, and names it in the summary" {
  _lint_fixture
  _fake_shellcheck
  _ctrl_here run lint --only shell
  assert_failure
  assert_contains "bad.sh"
  assert_contains "FAILED"
  grep -qx tool "${TEST_TMP}/shellcheck.args"   # shebang-detected script included
}

@test "lint passes when everything is clean" {
  _lint_fixture
  rm bad.sh
  _fake_shellcheck
  _ctrl_here run lint --only shell,json,yaml
  assert_success
  refute_contains "FAILED"
}

@test "lint catches invalid JSON and YAML without extra tools" {
  printf '{"a": \n' > broken.json
  printf 'a: [1\n' > broken.yaml
  _ctrl_here run lint --only json
  assert_failure
  assert_contains "invalid JSON: broken.json"
  if ! command -v yamllint >/dev/null; then
    _ctrl_here run lint --only yaml
    assert_failure
    assert_contains "invalid YAML: broken.yaml"
  fi
}

@test "lint --changed only looks at files changed since the base" {
  _git_init
  _lint_fixture
  git add . && git commit -qm base && git branch -M main
  git checkout -qb feature
  printf '#!/usr/bin/env bash\necho new\n' > new.sh
  _fake_shellcheck
  _ctrl_here run lint --changed --only shell
  assert_success
  [[ "$(sort -u "${TEST_TMP}/shellcheck.args")" == "new.sh" ]] || { cat "${TEST_TMP}/shellcheck.args"; return 1; }
}

@test "lint --fix runs the formatter" {
  printf '#!/usr/bin/env bash\necho ok\n' > good.sh
  _fake_shellcheck
  _fake shfmt 'echo "shfmt $*" >> "'"${TEST_TMP}"'/shfmt.log"'
  _ctrl_here run lint --only shell --fix
  assert_success
  grep -q -- '-w' "${TEST_TMP}/shfmt.log"
}

@test "lint dry-run prints the linter commands without running them" {
  _lint_fixture
  _fake_shellcheck
  _ctrl_here run lint -n --only shell
  assert_success
  assert_contains "shellcheck -S warning -x <shell 3 files>"
  [[ ! -f "${TEST_TMP}/shellcheck.args" ]] || return 1
}

@test "lint honours the project's .shellcheckrc (ShellCheck reads it itself)" {
  command -v shellcheck >/dev/null 2>&1 || skip "real shellcheck not installed"
  printf '#!/usr/bin/env bash\necho "${unset_from_elsewhere}"\n' > uses.sh
  _ctrl_here run lint --only shell
  assert_failure
  printf 'disable=SC2154\n' > .shellcheckrc
  _ctrl_here run lint --only shell
  assert_success
}

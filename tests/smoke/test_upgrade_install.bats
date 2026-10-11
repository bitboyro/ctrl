#!/usr/bin/env bats
# ctrl upgrade and install.sh against a fake GitHub: a curl on PATH that serves
# files from ${TEST_TMP}/gh by URL. Needs dist/ctrl — lives in smoke/ because the CI smoke job builds it.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  DIST_CTRL="${CTRL_REPO_ROOT}/dist/ctrl"
  [[ -x "${DIST_CTRL}" ]] || skip "dist/ctrl not built"
  export GH="${TEST_TMP}/gh"
  mkdir -p "${TEST_TMP}/bin" "${GH}"
  # fake curl: map the URL to a file under $GH, honour -o
  cat > "${TEST_TMP}/bin/curl" <<'CURL'
#!/usr/bin/env bash
out="" url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in -o) shift; out="$1" ;; -*) ;; *) url="$1" ;; esac
  shift
done
f="${GH}/$(printf '%s' "${url}" | sed 's|^https://||; s|/|_|g')"
[[ -f "${f}" ]] || exit 22
if [[ -n "${out}" ]]; then cp "${f}" "${out}"; else cat "${f}"; fi
CURL
  chmod +x "${TEST_TMP}/bin/curl"
  export PATH="${TEST_TMP}/bin:${PATH}"
  export CTRL_REPO="https://github.com/acme/ctrl"
}

teardown() { teardown_test_dir; }

_serve() {  # _serve <url-without-https> <file>
  cp "$2" "${GH}/$(printf '%s' "$1" | sed 's|/|_|g')"
}

_sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

# A "new release": the real dist with a bumped version
_release() {
  local v="$1"
  sed "s/^CTRL_VERSION=\".*\"/CTRL_VERSION=\"${v}\"/" "${DIST_CTRL}" > "${TEST_TMP}/new-ctrl"
  printf '{"tag_name": "v%s"}\n' "${v}" > "${TEST_TMP}/latest.json"
  printf '# Changelog\n\n## [%s] - 2030-01-01\n\n### Added\n- shiny thing\n\n## [0.0.1] - 2020-01-01\n\n### Added\n- ancient thing\n' "${v}" > "${TEST_TMP}/CHANGELOG.md"
  _serve "api.github.com/repos/acme/ctrl/releases/latest" "${TEST_TMP}/latest.json"
  _serve "raw.githubusercontent.com/acme/ctrl/v${v}/CHANGELOG.md" "${TEST_TMP}/CHANGELOG.md"
  _serve "github.com/acme/ctrl/releases/download/v${v}/ctrl" "${TEST_TMP}/new-ctrl"
  printf '%s  ctrl\n' "$(_sha "${TEST_TMP}/new-ctrl")" > "${TEST_TMP}/ctrl.sha256"
  _serve "github.com/acme/ctrl/releases/download/v${v}/ctrl.sha256" "${TEST_TMP}/ctrl.sha256"
}

@test "upgrade replaces a single-file install after checksum + version check" {
  _release 9.0.0
  mkdir -p "${TEST_TMP}/inst"; cp "${DIST_CTRL}" "${TEST_TMP}/inst/ctrl"
  run "${TEST_TMP}/inst/ctrl" upgrade < /dev/null
  assert_success
  assert_contains "SHA256 verified"
  assert_contains "shiny thing"
  refute_contains "ancient thing"
  assert_eq "$("${TEST_TMP}/inst/ctrl" version)" "ctrl v9.0.0"
}

@test "upgrade refuses a download whose checksum does not match" {
  _release 9.0.0
  echo "0000  ctrl" > "${TEST_TMP}/bad.sha256"
  _serve "github.com/acme/ctrl/releases/download/v9.0.0/ctrl.sha256" "${TEST_TMP}/bad.sha256"
  mkdir -p "${TEST_TMP}/inst"; cp "${DIST_CTRL}" "${TEST_TMP}/inst/ctrl"
  run "${TEST_TMP}/inst/ctrl" upgrade < /dev/null
  assert_failure
  assert_contains "Checksum mismatch"
  cmp -s "${DIST_CTRL}" "${TEST_TMP}/inst/ctrl" || { echo "binary was modified"; return 1; }
}

@test "upgrade --dry-run only shows the changelog" {
  _release 9.0.0
  mkdir -p "${TEST_TMP}/inst"; cp "${DIST_CTRL}" "${TEST_TMP}/inst/ctrl"
  run "${TEST_TMP}/inst/ctrl" --dry-run upgrade
  assert_success
  assert_contains "shiny thing"
  cmp -s "${DIST_CTRL}" "${TEST_TMP}/inst/ctrl" || return 1
}

@test "upgrade says up to date when the latest release is not newer" {
  printf '{"tag_name": "v0.0.1"}\n' > "${TEST_TMP}/latest.json"
  _serve "api.github.com/repos/acme/ctrl/releases/latest" "${TEST_TMP}/latest.json"
  run "${DIST_CTRL}" upgrade
  assert_success
  assert_contains "up to date"
}

@test "upgrade from a source checkout points at install.sh" {
  _release 9.0.0
  run "${CTRL_REPO_ROOT}/ctrl.sh" upgrade < /dev/null
  assert_success
  assert_contains "source install"
  assert_contains "install.sh"
}

@test "install.sh installs a verified release binary" {
  _release 9.0.0
  _serve "github.com/acme/ctrl/releases/download/v9.0.0/ctrl" "${TEST_TMP}/new-ctrl"
  cd "${TEST_TMP}"
  run env CTRL_BIN_DIR="${TEST_TMP}/bin2" HOME="${TEST_TMP}" bash "${CTRL_REPO_ROOT}/install.sh" v9.0.0
  assert_success
  assert_contains "SHA256 verified"
  assert_eq "$("${TEST_TMP}/bin2/ctrl" version)" "ctrl v9.0.0"
}

@test "install.sh refuses a tampered binary" {
  _release 9.0.0
  echo 'echo pwned' >> "${TEST_TMP}/new-ctrl"
  _serve "github.com/acme/ctrl/releases/download/v9.0.0/ctrl" "${TEST_TMP}/new-ctrl"
  cd "${TEST_TMP}"
  run env CTRL_BIN_DIR="${TEST_TMP}/bin2" HOME="${TEST_TMP}" bash "${CTRL_REPO_ROOT}/install.sh" v9.0.0
  assert_failure
  assert_contains "Checksum mismatch"
  [[ ! -e "${TEST_TMP}/bin2/ctrl" ]] || return 1
}

#!/usr/bin/env bats
# Unit tests for doctor.sh — _doctor_best_install priority and env var scanning.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  source_libs core.sh doctor.sh
  CTRL_YAML='{}'
}

teardown() { teardown_test_dir; }

# ── install plan (platform.sh) ─────────────────────────────────────────────

_plan() { CTRL_OS="$1" CTRL_ARCH="$2" CTRL_PKG="$3"; CTRL_TOOLS_YAML=""; _ctrl_install_plan "$4"; }

@test "install plan uses the native package manager first" {
  _plan linux amd64 apt jq
  assert_eq "${CTRL_INSTALL_KIND}" "pkg"
  [[ "${CTRL_INSTALL_TEXT}" == *"apt-get install -y jq" ]] || return 1
  _plan darwin arm64 brew jq
  assert_eq "${CTRL_INSTALL_TEXT}" "brew install jq"
  _plan linux amd64 dnf ssh
  [[ "${CTRL_INSTALL_TEXT}" == *"dnf install -y openssh-clients" ]] || return 1
}

@test "install plan maps a tool to its per-manager package name" {
  _plan linux amd64 apt nc
  [[ "${CTRL_INSTALL_TEXT}" == *"netcat-openbsd" ]] || return 1
  _plan linux amd64 apk qrencode
  [[ "${CTRL_INSTALL_TEXT}" == *"apk add libqrencode-tools" ]] || return 1
}

@test "install plan falls back to a download URL with os/arch substituted" {
  _plan linux arm64 apt yq
  assert_eq "${CTRL_INSTALL_KIND}" "url"
  assert_eq "${CTRL_INSTALL_URL}" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64"
  _plan darwin amd64 none yq
  assert_eq "${CTRL_INSTALL_URL}" "https://github.com/mikefarah/yq/releases/latest/download/yq_darwin_amd64"
}

@test "install plan prefers the per-OS URL over the generic one" {
  _plan darwin arm64 none jq
  assert_eq "${CTRL_INSTALL_URL}" "https://github.com/jqlang/jq/releases/latest/download/jq-macos-arm64"
}

@test "yq is never installed from pip" {
  local pkg
  for pkg in apt dnf none; do
    _plan linux amd64 "${pkg}" yq
    [[ "${CTRL_INSTALL_TEXT}" != *pip* ]] || { echo "pip offered with ${pkg}"; return 1; }
  done
}

@test "tools without an install source return a hint" {
  _plan darwin arm64 brew docker
  assert_eq "${CTRL_INSTALL_KIND}" "hint"
  assert_eq "${CTRL_INSTALL_TEXT}" "ctrl run install-docker"
}

@test "meta.tools entries are merged on top of the registry (legacy keys accepted)" {
  CTRL_YAML='meta:
  tools:
    - name: scanos
      description: "Disk scanner"
      install:
        brew: scanos
        curl: https://example.com/scanos
    - name: jq
      why: "project jq"
      install:
        brew: jq-custom'
  _plan darwin arm64 brew scanos
  assert_eq "${CTRL_INSTALL_TEXT}" "brew install scanos"
  _plan linux amd64 none scanos
  assert_eq "${CTRL_INSTALL_URL}" "https://example.com/scanos"
  assert_eq "$(ctrl_tool_field scanos .why)" "Disk scanner"
  _plan darwin arm64 brew jq
  assert_eq "${CTRL_INSTALL_TEXT}" "brew install jq-custom"
}

@test "ctrl_install_tool refuses package names with shell metacharacters" {
  CTRL_YAML='meta:
  tools:
    - name: evil
      install:
        brew: "x;touch /tmp/pwned"'
  CTRL_OS=darwin CTRL_PKG=brew CTRL_TOOLS_YAML=""
  run ctrl_install_tool evil
  assert_failure
  assert_contains "unsafe"
}

@test "ctrl_version_ge compares dotted versions numerically" {
  ctrl_version_ge 4.53.2 4.18
  ctrl_version_ge 1.10 1.9
  ctrl_version_ge 2.0 2
  if ctrl_version_ge 4.9 4.18; then return 1; fi
  if ctrl_version_ge 1.6 1.7.1; then return 1; fi
}

@test "doctor reports platform and runs without a ctrl.yaml" {
  cd "${TEST_TMP}"
  run env -u CTRL_CONFIG "${CTRL_REPO_ROOT}/ctrl.sh" doctor
  assert_contains "platform"
  assert_contains "none found"
}

# ── _doctor_check_env_vars ─────────────────────────────────────────────────

@test "_doctor_check_env_vars reports set vars as set" {
  export MY_CTRL_TEST_HOST="10.0.0.1"
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "${MY_CTRL_TEST_HOST}"
YAML
  CTRL_CONFIG_FILE="${TEST_TMP}/ctrl.yaml"
  source_libs core.sh doctor.sh
  local all_ok=1
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    export MY_CTRL_TEST_HOST=10.0.0.1
    _doctor_check_env_vars all_ok
  "
  assert_success
  assert_contains "MY_CTRL_TEST_HOST"
  assert_contains "set"
}

@test "_doctor_check_env_vars reports unset vars" {
  unset MY_CTRL_UNSET_VAR
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "${MY_CTRL_UNSET_VAR}"
YAML
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    unset MY_CTRL_UNSET_VAR
    all_ok=1
    _doctor_check_env_vars all_ok
  "
  assert_success
  assert_contains "MY_CTRL_UNSET_VAR"
  assert_contains "unset"
}

@test "_doctor_check_env_vars produces no env-var output when ctrl.yaml has no \${VAR} references" {
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "10.0.0.1"
YAML
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    all_ok=1
    _doctor_check_env_vars all_ok
  "
  # No env var scan lines should appear regardless of nameref support
  refute_contains "unset"
  refute_contains "VAR"
}

@test "_doctor_check_env_vars also finds unbraced \$VAR references" {
  cat > "${TEST_TMP}/ctrl.yaml" <<'YAML'
ctrl:
  version: "0.0.1"
meta:
  project: test
  registry: docker.io/test
machines:
  hosts:
    - name: vm
      host: "$MY_CTRL_UNBRACED_VAR"
YAML
  run bash -c "
    source '${CTRL_REPO_ROOT}/lib/core.sh'
    source '${CTRL_REPO_ROOT}/lib/doctor.sh'
    CTRL_CONFIG_FILE='${TEST_TMP}/ctrl.yaml'
    unset MY_CTRL_UNBRACED_VAR
    all_ok=1
    _doctor_check_env_vars all_ok
  "
  assert_success
  assert_contains "MY_CTRL_UNBRACED_VAR"
  assert_contains "unset"
}

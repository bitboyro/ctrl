#!/usr/bin/env bats
# Unit tests for `ctrl run --on`: target expansion, remote streaming (via a fake
# ssh that executes the remote command locally), fan-out prefixes, summary and
# combined exit code, remote pre-flight preamble.

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

# Fake ssh: log the target, then run the remote command string locally with
# the streamed stdin — the same thing a real sshd would do.
_write_fake_ssh() {
  mkdir -p "${TEST_TMP}/bin"
  cat > "${TEST_TMP}/bin/ssh" <<'SSH'
#!/usr/bin/env bash
target=""
while [[ "$#" -gt 1 ]]; do
  case "$1" in
    -p|-i|-o) shift 2 ;;
    -t) shift ;;
    *) target="$1"; shift ;;
  esac
done
echo "${target}" >> "${FAKE_SSH_LOG}"
export FAKE_HOST="${target#*@}"
exec bash -c "$1"
SSH
  chmod +x "${TEST_TMP}/bin/ssh"
  export PATH="${TEST_TMP}/bin:${PATH}"
  export FAKE_SSH_LOG="${TEST_TMP}/ssh.log"
}

setup() {
  setup_test_dir
  write_fixture_yaml
  yq -i '.machines.hosts = [
      {"name":"web1","host":"10.0.0.1","tags":["web"]},
      {"name":"web2","host":"10.0.0.2","tags":["web"]},
      {"name":"db1","host":"10.0.0.3","tags":["db"]}]
    | .machines.default = "web1"
    | .deployments.targets = [{"name":"prod","machine":"db1","compose_path":"/opt/p/docker-compose.yml"}]
    | .deployments.default = "prod"' "${TEST_TMP}/ctrl.yaml"
  mkdir -p "${TEST_TMP}/scripts" "${TEST_TMP}/.local"   # .local keeps the journal in the test dir
  cat > "${TEST_TMP}/scripts/where.sh" <<'SH'
#!/usr/bin/env bash
echo "on=${FAKE_HOST:-local} machine=${CTRL_MACHINE_NAME} remote=${CTRL_REMOTE:-0} args=$*"
SH
  _write_fake_ssh
}

teardown() { teardown_test_dir; }

@test "--on <machine> streams the script over ssh with ctrl env and args" {
  run_ctrl run where --on web2 a "b c"
  assert_success
  assert_contains "on=10.0.0.2 machine=web2 remote=1 args=a b c"
  grep -q 'root@10.0.0.2' "${FAKE_SSH_LOG}" || return 1
}

@test "--on <deployment> resolves the deployment's machine" {
  run_ctrl run where --on prod
  assert_success
  assert_contains "on=10.0.0.3"
}

@test "--on local runs on this machine" {
  run_ctrl run where --on local
  assert_success
  assert_contains "on=local"
  [[ ! -f "${FAKE_SSH_LOG}" ]] || return 1
}

@test "--on a,b fans out with per-host prefixes and a summary" {
  run_ctrl run where --on web1,db1
  assert_success
  assert_contains "web1 | on=10.0.0.1"
  assert_contains "db1  | on=10.0.0.3"
  assert_contains "HOST"
  [[ "$(grep -c . "${FAKE_SSH_LOG}")" == "2" ]] || return 1
}

@test "--on @tag selects machines by tag" {
  run_ctrl run where --on @web
  assert_success
  assert_contains "on=10.0.0.1"
  assert_contains "on=10.0.0.2"
  refute_contains "on=10.0.0.3"
}

@test "--on all runs on every machine" {
  run_ctrl run where --on all
  assert_success
  [[ "$(sort -u "${FAKE_SSH_LOG}" | grep -c .)" == "3" ]] || return 1
}

@test "--on mixes local and remote targets" {
  run_ctrl run where --on local,web1
  assert_success
  assert_contains "on=local"
  assert_contains "on=10.0.0.1"
}

@test "fan-out exit code is non-zero when any host fails, and names it" {
  cat > "${TEST_TMP}/scripts/flaky.sh" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_HOST}" == "10.0.0.2" ]] && exit 7
echo fine
SH
  run_ctrl run flaky --on @web
  assert_failure
  assert_contains "web2  failed (exit 7)"
  assert_contains "web1  ok"
}

@test "unknown --on target and empty tag fail clearly" {
  run_ctrl run where --on nowhere
  assert_failure
  assert_contains "Unknown target 'nowhere'"
  run_ctrl run where --on @nosuchtag
  assert_failure
  assert_contains "No machines tagged 'nosuchtag'"
}

@test "remote pre-flight stops the script when a tool is missing on the host" {
  cat > "${TEST_TMP}/scripts/needy.sh" <<'SH'
#!/usr/bin/env bash
# @requires: __ctrl_missing_on_remote__
echo "BODY RAN"
SH
  run_ctrl run needy --on web1
  assert_failure
  assert_contains "remote requires __ctrl_missing_on_remote__"
  refute_contains "BODY RAN"
}

@test "remote pre-flight checks @os against the host's uname" {
  cat > "${TEST_TMP}/scripts/osbound.sh" <<'SH'
#!/usr/bin/env bash
# @os: __otheros__
echo "BODY RAN"
SH
  run_ctrl run osbound --on web1
  assert_failure
  assert_contains "supports: __otheros__"
  refute_contains "BODY RAN"
}

@test "--check --on runs only the preamble remotely" {
  cat > "${TEST_TMP}/scripts/chk.sh" <<'SH'
#!/usr/bin/env bash
# @requires: bash
echo "BODY RAN"
SH
  run_ctrl run chk --check --on web1,web2
  assert_success
  assert_contains "web1 | pre-flight ok"
  assert_contains "web2 | pre-flight ok"
  refute_contains "BODY RAN"
}

@test "@remote: no scripts refuse --on" {
  cat > "${TEST_TMP}/scripts/deskonly.sh" <<'SH'
#!/usr/bin/env bash
# @remote: no
echo hi
SH
  run_ctrl run deskonly --on web1
  assert_failure
  assert_contains "local-only"
}

@test "dry-run --on prints the ssh command and preamble without connecting" {
  cat > "${TEST_TMP}/scripts/needy.sh" <<'SH'
#!/usr/bin/env bash
# @requires: jq
echo hi
SH
  run_ctrl run needy --on web1 -n
  assert_success
  assert_contains "[DRY-RUN] ssh root@10.0.0.1: env CTRL_PROJECT="
  assert_contains "bash -s"
  assert_contains "command -v jq"
  [[ ! -f "${FAKE_SSH_LOG}" ]] || return 1
}

@test "remote args are quoted so they cannot inject commands" {
  run_ctrl run where --on web1 '$(touch '"${TEST_TMP}"'/pwned)' ';id'
  assert_success
  [[ ! -e "${TEST_TMP}/pwned" ]] || return 1
  assert_contains 'args=$(touch'
}

@test "journal records one run entry per host" {
  run_ctrl run where --on web1,web2
  local journal="${TEST_TMP}/.local/journal/journal.jsonl"
  run bash -c "tail -n 5 '${journal}' | jq -r 'select(.command==\"run\" and .services==\"where\") | .host' | sort -u"
  assert_contains "10.0.0.1"
  assert_contains "10.0.0.2"
}

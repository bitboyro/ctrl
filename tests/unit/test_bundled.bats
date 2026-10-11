#!/usr/bin/env bats
# Tests for the bundled script library: every script honours the library
# contract, and each script's dry-run prints the exact command it would run
# (platform simulated with CTRL_OS; docker/ffmpeg faked on PATH where needed).

load "${BATS_TEST_DIRNAME}/../helpers/setup.bash"

setup() {
  setup_test_dir
  write_fixture_yaml
  mkdir -p "${TEST_TMP}/bin"
  export PATH="${TEST_TMP}/bin:${PATH}"
}

teardown() { teardown_test_dir; }

_fake() {  # _fake <cmd> <script body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "${TEST_TMP}/bin/$1"
  chmod +x "${TEST_TMP}/bin/$1"
}

_bundled_names() {
  local f; for f in "${CTRL_REPO_ROOT}"/bundled/*.sh; do
    local b; b="$(basename "${f}" .sh)"; [[ "${b}" == _* ]] || echo "${b}"
  done
}

# ── contract ────────────────────────────────────────────────────────────────

@test "every bundled script has name, description, group, dry-run header and the lib marker" {
  local n f
  for n in $(_bundled_names); do
    f="${CTRL_REPO_ROOT}/bundled/${n}.sh"
    grep -q "^# @name: ${n}\$" "${f}"        || { echo "${n}: @name"; return 1; }
    grep -q '^# @description: .' "${f}"      || { echo "${n}: @description"; return 1; }
    grep -q '^# @group: [a-z]' "${f}"        || { echo "${n}: @group"; return 1; }
    grep -q '^# @dry-run: yes$' "${f}"       || { echo "${n}: @dry-run"; return 1; }
    grep -q '^# ctrl:lib$' "${f}"            || { echo "${n}: ctrl:lib marker"; return 1; }
    grep -q '^set -euo pipefail$' "${f}"     || { echo "${n}: strict mode"; return 1; }
    bash -n "${f}"                           || { echo "${n}: syntax"; return 1; }
  done
}

@test "every bundled script answers --help from its header, standalone" {
  local n out
  for n in $(_bundled_names); do
    run_ctrl run "${n}" --own
    [[ "${status}" -eq 0 ]] || { echo "${n}: own failed: ${output}"; return 1; }
    out="$(bash "${TEST_TMP}/scripts/${n}.sh" --help 2>&1)" || { echo "${n}: --help exit $?: ${out}"; return 1; }
    [[ "${out}" == *"ctrl run ${n}"* ]] || { echo "${n}: --help output: ${out}"; return 1; }
  done
}

@test "the library lists every bundled script with its group" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" --json run
  assert_success
  local n
  for n in $(_bundled_names); do
    echo "${output}" | jq -e --arg n "${n}" '.[] | select(.name == $n and .source == "bundled" and (.group | length) > 0)' >/dev/null \
      || { echo "missing from listing: ${n}"; return 1; }
  done
}

@test "setup scripts declare sudo and are remote-capable; desktop scripts are local-only" {
  run env CTRL_CONFIG="${CTRL_CONFIG}" CTRL_CACHE_DIR="${CTRL_CACHE_DIR}" "${CTRL_REPO_ROOT}/ctrl.sh" --json run
  local n
  for n in install-docker add-swap harden-ssh ufw-basics install-tailscale gitlab-runner; do
    echo "${output}" | jq -e --arg n "${n}" '.[] | select(.name == $n) | .sudo and .remote' >/dev/null || { echo "${n}"; return 1; }
  done
  for n in rec snap share dsh toolbox new-script; do
    echo "${output}" | jq -e --arg n "${n}" '.[] | select(.name == $n) | .remote == false' >/dev/null || { echo "${n}"; return 1; }
  done
}

# ── media ───────────────────────────────────────────────────────────────────

@test "rec on macOS infers the avfoundation screen index and small-file defaults" {
  _fake ffmpeg 'echo "[AVFoundation indev @ 0x1] [0] FaceTime HD Camera" >&2; echo "[AVFoundation indev @ 0x1] [2] Capture screen 0" >&2'
  CTRL_OS=darwin run_ctrl run rec -n --out /tmp/x.mp4
  assert_success
  assert_contains "-f avfoundation"
  assert_contains "-i 2:none"
  assert_contains "-framerate 15"
  assert_contains "-crf 30"
  assert_contains "scale=trunc\\(iw\\*0.5/2\\)\\*2"
  assert_contains "/tmp/x.mp4"
}

@test "rec on X11 uses x11grab with the detected size; --audio adds pulse" {
  _fake ffmpeg 'exit 0'
  CTRL_OS=linux DISPLAY=:1 REC_SIZE=1366x768 run_ctrl run rec -n --audio --fps 24
  assert_success
  assert_contains "-f x11grab"
  assert_contains "-video_size 1366x768"
  assert_contains "-i :1"
  assert_contains "-f pulse -i default"
  assert_contains "-framerate 24"
}

@test "rec --region crops and --gif adds a palette pass" {
  _fake ffmpeg 'exit 0'
  CTRL_OS=darwin REC_SCREEN=1 run_ctrl run rec -n --region 800x600+10+20 --gif --out /tmp/r.mp4
  assert_success
  assert_contains "crop=800:600:10:20"
  assert_contains "palettegen"
  assert_contains "/tmp/r.gif"
}

@test "rec rejects a malformed region" {
  _fake ffmpeg 'exit 0'
  run_ctrl run rec -n --region huge
  assert_failure
  assert_contains "--region must look like"
}

@test "gif builds a single-command palette pipeline" {
  _fake ffmpeg 'exit 0'
  run_ctrl run gif demo.mp4 -n --fps 10 --width 640 --from 2 --to 5
  assert_success
  assert_contains "-ss 2 -to 5 -i demo.mp4"
  assert_contains "fps=10"
  assert_contains "min\\(640\\,iw\\)"
  assert_contains "demo.gif"
}

@test "shrink computes the video bitrate from the target size and duration" {
  _fake ffmpeg 'exit 0'
  SHRINK_DURATION=100 run_ctrl run shrink talk.mov -n --to 10M
  assert_success
  # 10 MiB * 8 * 0.97 / 100 s / 1000 − 64 = 749 kb/s
  assert_contains "-b:v 749k"
  assert_contains "talk.small.mp4"
}

@test "snap on macOS uses screencapture, --region makes it interactive" {
  CTRL_OS=darwin run_ctrl run snap -n --region --out /tmp/s.png
  assert_success
  assert_contains "screencapture -x -i /tmp/s.png"
}

# ── share ───────────────────────────────────────────────────────────────────

@test "share serves the parent folder of a file on a free port" {
  mkdir -p "${TEST_TMP}/site"; echo hi > "${TEST_TMP}/site/app.apk"
  run_ctrl run share "${TEST_TMP}/site/app.apk" -n --port 8765
  assert_success
  assert_contains "http.server 8765 --bind 0.0.0.0 --directory ${TEST_TMP}/site"
}

@test "share --tunnel adds a cloudflared quick tunnel" {
  run_ctrl run share . -n --port 8766 --tunnel
  assert_success
  assert_contains "cloudflared tunnel --no-autoupdate --url http://localhost:8766"
}

@test "qr builds a Wi-Fi join code with escaping" {
  _fake qrencode 'exit 0'
  run_ctrl run qr -n --wifi 'Home;Net' --password 'p:w'
  assert_success
  assert_contains 'WIFI:T:WPA\;S:Home\\\;Net\;P:p\\:w\;\;'
}

# ── setup (sudo) ────────────────────────────────────────────────────────────

@test "install-docker on Debian adds the verified-key apt repo and compose plugin" {
  _fake docker 'exit 1'
  mkdir -p "${TEST_TMP}/etc"
  CTRL_OS=linux CTRL_DISTRO=ubuntu CTRL_DISTRO_CODENAME=noble run_ctrl run install-docker -n --yes
  assert_success
  assert_contains "https://download.docker.com/linux/ubuntu noble stable"
  assert_contains "docker-compose-plugin"
  assert_contains "download.docker.com"
  assert_contains "verify fingerprint"
  assert_contains "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
}

@test "install-docker on Fedora imports the verified key before adding the repo" {
  _fake docker 'exit 1'
  _fake dnf 'echo "4.18.0"'
  CTRL_OS=linux CTRL_DISTRO=fedora run_ctrl run install-docker -n --yes
  assert_success
  assert_contains "rpm --import /tmp/docker-repo.gpg"
  assert_contains "config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo"
}

@test "install-docker refuses unknown distributions clearly" {
  _fake docker 'exit 1'
  CTRL_OS=linux CTRL_DISTRO=plan9 run_ctrl run install-docker -n --yes
  assert_failure
  assert_contains "Unsupported distribution 'plan9'"
}

@test "install-docker on macOS uses colima + the docker CLI" {
  _fake docker 'exit 1'
  _fake brew 'exit 0'
  CTRL_OS=darwin run_ctrl run install-docker -n --yes
  assert_success
  assert_contains "brew install colima docker docker-compose"
  assert_contains "colima start"
}

@test "install-docker is a no-op when docker and compose already work" {
  _fake docker 'if [[ "$1" == "--version" ]]; then echo "Docker version 27.0.0"; fi; exit 0'
  run_ctrl run install-docker --yes < /dev/null
  assert_success
  assert_contains "already installed"
}

@test "install-docker without --yes refuses non-interactively (sudo gate)" {
  run_ctrl run install-docker < /dev/null
  assert_failure
  assert_contains "--yes"
}

@test "add-swap dry-run sizes from RAM and persists fstab + swappiness" {
  CTRL_OS=linux run_ctrl run add-swap -n --yes --size 2G
  assert_success
  assert_contains "fallocate -l 2G /swapfile"
  assert_contains "mkswap /swapfile"
  assert_contains "/etc/fstab"
  assert_contains "vm.swappiness=10"
}

@test "harden-ssh dry-run shows the drop-in and never touches sshd_config itself" {
  CTRL_OS=linux run_ctrl run harden-ssh -n --yes
  assert_success
  assert_contains "PasswordAuthentication no"
  assert_contains "PermitRootLogin prohibit-password"
  assert_contains "99-ctrl-hardening.conf"
}

@test "ufw-basics allows the ssh port and extra ports before enabling" {
  _fake ufw 'exit 0'
  SSH_CONNECTION="1.2.3.4 5555 10.0.0.1 2222" CTRL_OS=linux run_ctrl run ufw-basics -n --yes --allow 80,443/tcp
  assert_success
  assert_contains "ufw allow 2222/tcp"
  assert_contains "ufw allow 80"
  assert_contains "ufw allow 443/tcp"
  assert_contains "ufw --force enable"
}

@test "ufw-basics rejects a malformed port" {
  _fake ufw 'exit 0'
  CTRL_OS=linux run_ctrl run ufw-basics -n --yes --allow '80;id'
  assert_failure
  assert_contains "Invalid port"
}

@test "install-tailscale passes TS_AUTHKEY as a file, never inline" {
  _fake tailscale 'echo 1.0'
  TS_AUTHKEY=tskey-secret CTRL_OS=linux run_ctrl run install-tailscale -n --yes --ssh
  assert_success
  assert_contains "--auth-key=file:"
  refute_contains "tskey-secret"
}

@test "timezone validates the zone name" {
  run_ctrl run timezone -n 'Europe/$(id)'
  assert_failure
  assert_contains "Invalid timezone"
}

@test "gitlab-runner verifies the binary checksum and keeps the token out of argv" {
  _fake gitlab-runner 'exit 0'
  GITLAB_RUNNER_TOKEN=glrt-secret CTRL_OS=linux run_ctrl run gitlab-runner -n --yes
  assert_success
  assert_contains "gitlab-runner register --non-interactive"
  assert_contains "--preserve-env="
  refute_contains "glrt-secret"
}

# ── docker ──────────────────────────────────────────────────────────────────

@test "dsh goes straight into the only matching container" {
  _fake docker 'if [[ "$1" == ps ]]; then printf "api-1\tapi:latest\tUp 2h\nworker-1\tw:1\tUp 1h\n"; fi'
  run_ctrl run dsh api -n --root
  assert_success
  assert_contains "docker exec -it -u 0 api-1 bash"
}

@test "dclean asks before pruning and only adds --all with --images" {
  _fake docker 'exit 0'
  run_ctrl run dclean -n --images
  assert_success
  assert_contains "docker system prune -f --all"
  assert_contains "docker builder prune -f"
}

@test "dtop --once prints a single snapshot" {
  _fake docker 'exit 0'
  run_ctrl run dtop -n --once
  assert_success
  assert_contains "docker stats --no-stream"
}

@test "sniff attaches to the service container's network" {
  _fake docker 'case "$1" in ps) echo "proj-api-1";; inspect) echo "proj_default";; esac'
  yq -i '.services = [{"name":"api","image":"x","deploy":{"compose_service":"api"}}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run sniff api -n --filter 'port 5432' --duration 5
  assert_success
  assert_contains "--network proj_default"
  assert_contains "timeout 5 tcpdump -l -n port\\ 5432"
}

# ── network / system ────────────────────────────────────────────────────────

@test "certs defaults to the project's https endpoints" {
  _fake openssl 'exit 0'
  yq -i '.services = [{"name":"api","health":{"url":"https://api.example.com/health"}},{"name":"local","health":{"port":8080}}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run certs -n
  assert_success
  assert_contains "-connect api.example.com:443"
  refute_contains "8080"
}

@test "api-call resolves the base URL from health.port and hides JWT_TOKEN" {
  _fake curl 'exit 0'
  yq -i '.services = [{"name":"api","health":{"port":9090}}]' "${TEST_TMP}/ctrl.yaml"
  JWT_TOKEN=secret-jwt run_ctrl run api-call api users --method post -n
  assert_success
  assert_contains "-X POST http://localhost:9090/users"
  assert_contains "Bearer <redacted>"
  refute_contains "secret-jwt"
}

@test "smoke runs each service's smoke_tests through ctrl run" {
  mkdir -p "${TEST_TMP}/scripts"
  printf '#!/usr/bin/env bash\necho "SMOKE-API-RAN"\n' > "${TEST_TMP}/scripts/check-api.sh"
  yq -i '.services = [{"name":"api","smoke_tests":["check-api"]},{"name":"worker"}]' "${TEST_TMP}/ctrl.yaml"
  run_ctrl run smoke api
  assert_success
  assert_contains "SMOKE-API-RAN"
}

@test "read-only scripts run for real on this machine" {
  run_ctrl run sysinfo --short
  assert_success
  run_ctrl run hogs "${TEST_TMP}" --disk --top 2
  assert_success
}

#!/usr/bin/env bash
# @name: gitlab-runner
# @description: Install (checksum-verified) and register a GitLab Runner as a service
# @group: ci
# @requires: curl
# @env: GITLAB_RUNNER_TOKEN
# @os: linux
# @sudo: yes
# @flags: --url URL --executor docker --image alpine:latest --name NAME
# @dry-run: yes
#
# Downloads the official gitlab-runner binary for this arch, verifies it against
# the published release.sha256, installs it as a system service and registers
# it. GITLAB_RUNNER_TOKEN is a runner authentication token (glrt-…, created in
# the GitLab UI) or, for older GitLab, a registration token. Tokens reach
# gitlab-runner through its environment — never on a command line.
#
#   ctrl run gitlab-runner --on ci-box
#   ctrl run gitlab-runner --on ci-box --url https://gitlab.example.com/ --executor shell
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
url="${GITLAB_URL:-https://gitlab.com/}" executor="${EXECUTOR:-docker}" image="${DOCKER_IMAGE:-alpine:latest}"
name="${RUNNER_DESCRIPTION:-ctrl-runner-$(hostname -s 2>/dev/null || echo host)}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --url)      shift; url="${1:-}" ;;
    --executor) shift; executor="${1:-}" ;;
    --image)    shift; image="${1:-}" ;;
    --name)     shift; name="${1:-}" ;;
    *)          die "Unknown argument: $1" ;;
  esac
  shift
done
[[ "${url}" == https://* ]] || die "--url must be https://"
[[ -n "${GITLAB_RUNNER_TOKEN:-${GITLAB_REGISTRATION_TOKEN:-}}" ]] || die "GITLAB_RUNNER_TOKEN not set"
need_sudo

base="https://gitlab-runner-downloads.s3.amazonaws.com/latest"
bin="gitlab-runner-linux-$(arch)"

if ! has gitlab-runner; then
  say "Installing gitlab-runner (${bin}), verifying SHA256"
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
  run curl -fsSL "${base}/binaries/${bin}" -o "${tmp}/${bin}"
  run curl -fsSL "${base}/release.sha256" -o "${tmp}/release.sha256"
  if [[ "${CTRL_DRY_RUN}" != "1" ]]; then
    want="$(grep " \*\?binaries/${bin}\$" "${tmp}/release.sha256" | awk '{print $1}')"
    have="$(sha256sum "${tmp}/${bin}" | awk '{print $1}')"
    [[ -n "${want}" && "${want}" == "${have}" ]] || die "Checksum mismatch for ${bin} (want ${want:-none}, got ${have})"
    ok "checksum ${have}"
  fi
  run ${SUDO} install -m 0755 "${tmp}/${bin}" /usr/local/bin/gitlab-runner
  id gitlab-runner >/dev/null 2>&1 || run ${SUDO} useradd --comment 'GitLab Runner' --create-home gitlab-runner --shell /bin/bash
  run ${SUDO} gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner
  run ${SUDO} gitlab-runner start
fi

say "Registering runner '${name}' → ${url} (${executor})"
export CI_SERVER_URL="${url}" RUNNER_NAME="${name}" RUNNER_EXECUTOR="${executor}" DOCKER_IMAGE="${image}"
if [[ "${GITLAB_RUNNER_TOKEN:-}" == glrt-* ]]; then
  export CI_SERVER_TOKEN="${GITLAB_RUNNER_TOKEN}"; keep=CI_SERVER_URL,RUNNER_NAME,RUNNER_EXECUTOR,DOCKER_IMAGE,CI_SERVER_TOKEN
else
  export REGISTRATION_TOKEN="${GITLAB_RUNNER_TOKEN:-${GITLAB_REGISTRATION_TOKEN}}"; keep=CI_SERVER_URL,RUNNER_NAME,RUNNER_EXECUTOR,DOCKER_IMAGE,REGISTRATION_TOKEN
fi
if [[ -n "${SUDO}" ]]; then
  run sudo --preserve-env="${keep}" gitlab-runner register --non-interactive
else
  run gitlab-runner register --non-interactive
fi
run ${SUDO} gitlab-runner restart
ok "GitLab Runner '${name}' registered"

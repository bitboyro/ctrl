#!/usr/bin/env bash
# @name: gitlab-info
# @description: Show a GitLab project's details from the API
# @group: ci
# @requires: curl jq
# @env: GITLAB_TOKEN
# @flags: <project-id-or-path>
# @dry-run: yes
#
# GITLAB_TOKEN comes from the env (ctrl loads meta.env_files and
# .local/secrets.env; .env.local in the project is also read). GITLAB_API_URL
# defaults to https://gitlab.com/api/v4. The token goes to curl on stdin.
#
#   ctrl run gitlab-info mygroup/myproject
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
project="${1:-}"
[[ -n "${project}" ]] || die "Usage: ctrl run gitlab-info <project-id-or-path>"

envfile="${CTRL_PROJECT_DIR:-${PWD}}/.env.local"
# shellcheck disable=SC1090
[[ -z "${GITLAB_TOKEN:-}" && -f "${envfile}" ]] && . "${envfile}"
[[ -n "${GITLAB_TOKEN:-}" ]] || die "GITLAB_TOKEN not set"

api="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
encoded="$(jq -rn --arg p "${project}" '$p | @uri')"
url="${api%/}/projects/${encoded}"

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  printf 'curl -sS --fail --header @- %q   # PRIVATE-TOKEN on stdin\n' "${url}"
  exit 0
fi
printf 'PRIVATE-TOKEN: %s\n' "${GITLAB_TOKEN}" | curl -sS --fail --header @- "${url}" | jq .

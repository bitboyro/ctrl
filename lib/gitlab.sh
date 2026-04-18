#!/usr/bin/env bash
# gitlab.sh — GitLab API integration and runner automation for ctrl

# Load secrets from .env.local if present
_gitlab_load_env() {
  local base
  base="$(dirname "${CTRL_CONFIG_FILE}")"
  if [ -f "$base/.env.local" ]; then
    set -a
    source "$base/.env.local"
    set +a
  fi
}

# Retrieve GitLab project info
ctrl_gitlab_project_info() {
  _gitlab_load_env
  require_cmd curl jq
  local project_id_or_path="$1"
  [[ -n "$project_id_or_path" ]] || fail "Usage: ctrl gitlab-project-info <project-id-or-path>"
  [[ -n "${GITLAB_TOKEN:-}" ]] || fail "GITLAB_TOKEN not set. Set it in .env.local or environment."
  local api_url
  api_url="${GITLAB_API_URL:-https://gitlab.com/api/v4}"
  local resp
  resp=$(curl -sS --fail --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$api_url/projects/$(ctrl_gitlab_urlencode "$project_id_or_path")") || fail "Failed to retrieve project info from GitLab API."
  echo "$resp" | jq .
}

# URL encode helper
ctrl_gitlab_urlencode() {
  local LANG=C
  local length="${#1}"
  for (( i = 0; i < length; i++ )); do
    local c="${1:i:1}"
    case $c in
      [a-zA-Z0-9.~_-]) printf "$c" ;;
      *) printf '%%%02X' "'${c}" ;;
    esac
  done
}

# Deploy and register a GitLab Runner
ctrl_gitlab_runner_deploy() {
  _gitlab_load_env
  require_cmd curl sudo
  [[ -n "${GITLAB_REGISTRATION_TOKEN:-}" ]] || fail "GITLAB_REGISTRATION_TOKEN not set. Set it in .env.local or environment."
  local url desc executor docker_image
  url="${GITLAB_URL:-https://gitlab.com/}"
  desc="${RUNNER_DESCRIPTION:-ctrl-runner}"
  executor="${EXECUTOR:-docker}"
  docker_image="${DOCKER_IMAGE:-alpine:latest}"
  # Install GitLab Runner if not present
  if ! has_cmd gitlab-runner; then
    msg "Installing GitLab Runner..."
    if has_cmd apt-get; then
      curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
      sudo apt-get install -y gitlab-runner
    elif has_cmd yum; then
      curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh | sudo bash
      sudo yum install -y gitlab-runner
    else
      fail "Unsupported OS. Please install gitlab-runner manually."
    fi
  fi
  # Register the runner
  sudo gitlab-runner register \
    --non-interactive \
    --url "$url" \
    --registration-token "$GITLAB_REGISTRATION_TOKEN" \
    --executor "$executor" \
    --docker-image "$docker_image" \
    --description "$desc"
  # Start the runner
  sudo systemctl restart gitlab-runner
  msg_ok "GitLab Runner deployed and registered as '$desc'."
}

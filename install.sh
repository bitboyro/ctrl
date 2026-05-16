#!/usr/bin/env bash
# ctrl installer — downloads ctrl and registers the Claude skill
set -euo pipefail

CTRL_VERSION_TAG="${CTRL_VERSION_TAG:-}"
CTRL_REPO="${CTRL_REPO:-https://github.com/bitboyro/ctrl}"
CTRL_BIN_DIR="${HOME}/.local/bin"
CTRL_INIT="${CTRL_INIT:-0}"  # set to 1 (or pass --init) to generate ctrl.yaml
CTRL_REF="main"              # git ref to download from

for arg in "$@"; do
  case "${arg}" in
    --init) CTRL_INIT=1 ;;
    v*|[0-9]*) CTRL_VERSION_TAG="${arg#v}"; CTRL_REF="v${CTRL_VERSION_TAG}" ;;
  esac
done

# Default to latest when no version argument is given
[[ -z "${CTRL_VERSION_TAG}" ]] && CTRL_VERSION_TAG="latest"

CTRL_INSTALL_DIR="${HOME}/.local/share/ctrl/${CTRL_VERSION_TAG}"

_print() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
_ok()    { printf '\033[1;32mok\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
_fail()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || _fail "curl is required"
command -v yq   >/dev/null 2>&1 || _warn "yq is not installed — ctrl requires yq (https://github.com/mikefarah/yq)"

if [[ "${CTRL_REF}" == "main" ]]; then
  RAW_BASE="${CTRL_REPO/github.com/raw.githubusercontent.com}/refs/heads/main"
else
  RAW_BASE="${CTRL_REPO/github.com/raw.githubusercontent.com}/refs/tags/${CTRL_REF}"
fi

_download() {
  local path="$1" dest="$2"
  mkdir -p "$(dirname "${dest}")"
  curl -fsSL "${RAW_BASE}/${path}" -o "${dest}"
}

_print "Installing ctrl v${CTRL_VERSION_TAG}"
_print "Destination: ${CTRL_INSTALL_DIR}"

mkdir -p "${CTRL_INSTALL_DIR}/lib" "${CTRL_INSTALL_DIR}/schema" "${CTRL_INSTALL_DIR}/agents" "${CTRL_BIN_DIR}"

_download "ctrl.sh"                         "${CTRL_INSTALL_DIR}/ctrl.sh"
_download "VERSION"                         "${CTRL_INSTALL_DIR}/VERSION"
_download "lib/core.sh"                     "${CTRL_INSTALL_DIR}/lib/core.sh"
_download "lib/services.sh"                 "${CTRL_INSTALL_DIR}/lib/services.sh"
_download "lib/deploy.sh"                   "${CTRL_INSTALL_DIR}/lib/deploy.sh"
_download "lib/remote.sh"                   "${CTRL_INSTALL_DIR}/lib/remote.sh"
_download "lib/health.sh"                   "${CTRL_INSTALL_DIR}/lib/health.sh"
_download "lib/audit.sh"                    "${CTRL_INSTALL_DIR}/lib/audit.sh"
_download "lib/ext.sh"                      "${CTRL_INSTALL_DIR}/lib/ext.sh"
_download "lib/gitlab.sh"                   "${CTRL_INSTALL_DIR}/lib/gitlab.sh"
_download "lib/templates.sh"               "${CTRL_INSTALL_DIR}/lib/templates.sh"
_download "lib/init.sh"                     "${CTRL_INSTALL_DIR}/lib/init.sh"
_download "lib/check.sh"                    "${CTRL_INSTALL_DIR}/lib/check.sh"
_download "lib/info.sh"                     "${CTRL_INSTALL_DIR}/lib/info.sh"
_download "lib/mcp.sh"                      "${CTRL_INSTALL_DIR}/lib/mcp.sh"
_download "schema/ctrl.schema.yaml"         "${CTRL_INSTALL_DIR}/schema/ctrl.schema.yaml"
_download "SKILL.md"                        "${CTRL_INSTALL_DIR}/SKILL.md"
_download "agents/milli.prompt.md"          "${CTRL_INSTALL_DIR}/agents/milli.prompt.md"
_download "agents/seb.prompt.md"            "${CTRL_INSTALL_DIR}/agents/seb.prompt.md"
_download "agents/asam.prompt.md"           "${CTRL_INSTALL_DIR}/agents/asam.prompt.md"

chmod +x "${CTRL_INSTALL_DIR}/ctrl.sh"

ln -sf "${CTRL_INSTALL_DIR}/ctrl.sh" "${CTRL_BIN_DIR}/ctrl"
_ok "ctrl v${CTRL_VERSION_TAG} installed → ${CTRL_BIN_DIR}/ctrl"

# ── register Claude skill ─────────────────────────────────────────────────────
_register_skill() {
  local skill_src="${CTRL_INSTALL_DIR}/SKILL.md"
  local project_skill_dir="${PWD}/.claude/skills/ctrl"
  local global_skill_dir="${HOME}/.claude/skills/ctrl"

  if [[ -d "${PWD}/.claude/skills" ]]; then
    mkdir -p "${project_skill_dir}"
    cp "${skill_src}" "${project_skill_dir}/SKILL.md"
    _ok "Claude skill registered: ${project_skill_dir}/SKILL.md"
  elif [[ -d "${HOME}/.claude/skills" ]]; then
    mkdir -p "${global_skill_dir}"
    cp "${skill_src}" "${global_skill_dir}/SKILL.md"
    _ok "Claude skill registered (global): ${global_skill_dir}/SKILL.md"
  else
    _warn "No .claude/skills directory found — skill not registered automatically"
    _warn "Copy ${skill_src} to .claude/skills/ctrl/SKILL.md manually"
  fi
}
_register_skill

# ── register Copilot agents ───────────────────────────────────────────────────
_register_agents() {
  local agents_src="${CTRL_INSTALL_DIR}/agents"
  local dest_dir

  # Prefer .github/prompts/ in the current project; fall back to home
  if [[ -d "${PWD}/.github" ]]; then
    dest_dir="${PWD}/.github/prompts"
  elif [[ -d "${PWD}/git" ]] || git -C "${PWD}" rev-parse --git-dir >/dev/null 2>&1; then
    local git_root; git_root="$(git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null || echo "${PWD}")"
    dest_dir="${git_root}/.github/prompts"
  else
    dest_dir="${HOME}/.github/prompts"
  fi

  mkdir -p "${dest_dir}"
  cp "${agents_src}/milli.prompt.md" "${dest_dir}/milli.prompt.md"
  cp "${agents_src}/seb.prompt.md"   "${dest_dir}/seb.prompt.md"
  cp "${agents_src}/asam.prompt.md"  "${dest_dir}/asam.prompt.md"
  _ok "Copilot agents registered: ${dest_dir}/{milli,seb,asam}.prompt.md"
}
_register_agents


# ── generate ctrl.yaml example ────────────────────────────────────────────────
_generate_example() {
  local dest="${PWD}/ctrl.yaml.example"
  cat >"${dest}" <<'YAML'
# ctrl.yaml — platform operations configuration
# Reference: https://github.com/bitboyro/ctrl
# Rename this file to ctrl.yaml. Secrets stay in .local/ctrl.local.yaml (gitignored).
# Run 'ctrl check' after filling in your values.

ctrl:
  version: "0.0.1"

meta:
  project: my-platform
  registry: docker.io/myorg
  env_files:
    - .env
    # - .local/secret.env

machines:
  default: prod-vm
  hosts:
    - name: prod-vm
      host: "${VM_HOST}"   # resolved from env at runtime — never hardcode
      user: root
      port: 22
      # key: "${SSH_KEY}"  # optional path to private key

services:
  - name: my-api
    description: "Backend API service"
    image: docker.io/myorg/my-api
    tag: latest
    build:
      tool: maven          # maven | gradle | npm | make | shell | skip
      dir: ../my-api
      # args: "-pl my-module -am"
      # prerequisites:
      #   - ../shared-lib
    deploy:
      compose_service: my-api
      # depends_on:
      #   - postgres
    health:
      port: 8080           # or: url: https://...
    smoke_tests:
      - smoke-api

  - name: my-web
    description: "Frontend (Next.js)"
    image: docker.io/myorg/my-web
    tag: latest
    build:
      tool: npm
      dir: ../my-web
    deploy:
      compose_service: my-web

  # External service — third-party image, no build/push
  # - name: grafana
  #   kind: external
  #   image: grafana/grafana
  #   tag: "10.2.0"
  #   deploy:
  #     compose_service: grafana
  #   health:
  #     port: 3000

scripts:
  - name: smoke-api
    path: scripts/smoke-api.sh
    description: "Quick API smoke test after deploy"

deployments:
  default: prod
  targets:
    - name: prod
      machine: prod-vm
      compose_path: /opt/scaffold/docker-compose.yml
      sync:
        paths:
          - scaffold/docker-compose.yml
          - scaffold/traefik
          - scaffold/prometheus
          - scaffold/.env

extensions: []
YAML
  _ok "Example config written: ${dest}"
}

if [[ "${CTRL_INIT}" == "1" ]]; then
  if [[ -f "${PWD}/ctrl.yaml" ]]; then
    _warn "ctrl.yaml already exists — writing example to ctrl.yaml.example instead"
    _generate_example
  else
    _generate_example
    mv "${PWD}/ctrl.yaml.example" "${PWD}/ctrl.yaml"
    _ok "ctrl.yaml created — edit it, then run: ctrl list"
  fi
else
  if [[ ! -f "${PWD}/ctrl.yaml" ]]; then
    _generate_example
    _warn "No ctrl.yaml found. A ctrl.yaml.example has been generated."
    _warn "Rename it to ctrl.yaml and fill in your values, or run 'ctrl' Claude skill to scaffold it."
  fi
fi

echo ""
echo "  ctrl v${CTRL_VERSION_TAG} is ready."
echo "  Make sure ${CTRL_BIN_DIR} is in your PATH, then run: ctrl help"

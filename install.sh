#!/usr/bin/env bash
# ctrl installer — downloads ctrl and registers the Claude skill
set -euo pipefail

CTRL_VERSION_TAG="${CTRL_VERSION_TAG:-0.1}"
CTRL_REPO="${CTRL_REPO:-https://github.com/bitboyro/ctrl}"
CTRL_INSTALL_DIR="${HOME}/.local/share/ctrl/${CTRL_VERSION_TAG}"
CTRL_BIN_DIR="${HOME}/.local/bin"
CTRL_INIT="${CTRL_INIT:-0}"  # set to 1 (or pass --init) to generate ctrl.yaml

for arg in "$@"; do
  case "${arg}" in
    --init) CTRL_INIT=1 ;;
  esac
done

_print() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
_ok()    { printf '\033[1;32mok\033[0m %s\n' "$*"; }
_warn()  { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
_fail()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || _fail "curl is required"
command -v yq   >/dev/null 2>&1 || _warn "yq is not installed — ctrl requires yq (https://github.com/mikefarah/yq)"

RAW_BASE="${CTRL_REPO/github.com/raw.githubusercontent.com}/refs/heads/main"

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
_download "schema/ctrl.schema.yaml"         "${CTRL_INSTALL_DIR}/schema/ctrl.schema.yaml"
_download "SKILL.md"                        "${CTRL_INSTALL_DIR}/SKILL.md"
_download "agents/milli.prompt.md"          "${CTRL_INSTALL_DIR}/agents/milli.prompt.md"
_download "agents/seb.prompt.md"            "${CTRL_INSTALL_DIR}/agents/seb.prompt.md"
_download "agents/masamune.prompt.md"       "${CTRL_INSTALL_DIR}/agents/masamune.prompt.md"

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
  cp "${agents_src}/milli.prompt.md"    "${dest_dir}/milli.prompt.md"
  cp "${agents_src}/seb.prompt.md"      "${dest_dir}/seb.prompt.md"
  cp "${agents_src}/masamune.prompt.md" "${dest_dir}/masamune.prompt.md"
  _ok "Copilot agents registered: ${dest_dir}/{milli,seb,masamune}.prompt.md"
}
_register_agents


# ── generate ctrl.yaml example ────────────────────────────────────────────────
_generate_example() {
  local dest="${PWD}/ctrl.yaml.example"
  cat >"${dest}" <<'YAML'
# ctrl.yaml — platform operations configuration
# Reference: https://github.com/bitboyro/ctrl
# Run 'ctrl help' after filling in your values.
# Rename this file to ctrl.yaml (secrets stay in .local/ctrl.local.yaml).

ctrl:
  version: "0.1"          # minimum ctrl version required by this config

meta:
  project: my-platform    # human-readable project name (used in audit log)
  registry: docker.io/myorg  # image registry prefix
  ssh_host: "${VM_HOST}"  # VM hostname or IP — resolved from env at runtime
  ssh_user: root          # SSH username
  ssh_port: "22"          # SSH port (default 22)
  # ssh_key: ~/.ssh/id_ed25519   # optional: path to private key
  compose_path: /opt/scaffold/docker-compose.yml  # path to docker-compose.yml on VM
  env_files:              # optional env files to source before running commands
    - .env                # non-secret config (checked in)
    # - .local/secret.env # secret overrides (gitignored)

services:
  # Each service maps to a buildable + deployable unit.
  - name: my-api          # unique identifier used in ctrl commands
    description: "Backend API service"
    image: docker.io/myorg/my-api   # full image name (no tag)
    tag: latest           # image tag; override per-service or in ctrl.local.yaml
    build:
      tool: maven         # maven | gradle | npm | make | shell | skip
      dir: ../my-api      # path to source dir (relative to ctrl.yaml)
      # args: "-pl my-module -am"  # extra args appended to the build command
      # prerequisites:    # build these first (relative dirs, must have mvnw/pom.xml)
      #   - ../shared-lib
      # dockerfile: Dockerfile           # relative to build.dir (default: Dockerfile)
      # context: .                       # docker build context (default: build.dir)
      # platform: linux/amd64            # target platform for buildx
    deploy:
      compose_service: my-api   # service name in docker-compose.yml
      # depends_on:       # start these compose services before deploying this one
      #   - postgres
      #   - kafka
    health:
      # url: https://api.example.com/actuator/health   # full URL (highest priority)
      port: 8080          # local port; ctrl constructs http://localhost:<port>/actuator/health
    smoke_tests:
      - smoke-api         # names of scripts (see scripts: below) to run as smoke tests
    # tag and image can be overridden in .local/ctrl.local.yaml per environment

  - name: my-web
    description: "Frontend (Next.js)"
    image: docker.io/myorg/my-web
    tag: latest
    build:
      tool: npm
      dir: ../my-web
    deploy:
      compose_service: my-web

# Named scripts — run with: ctrl run <name>
# Scripts receive CTRL_PROJECT, CTRL_SSH_HOST, CTRL_REGISTRY, CTRL_REMOTE_DIR as env vars.
scripts:
  - name: smoke-api
    path: scripts/smoke-api.sh
    description: "Quick API smoke test after deploy"
  # - name: seed-db
  #   path: scripts/seed-db.sh
  #   description: "Seed local postgres with fixture data"

# Files/directories to copy to the VM during sync-scaffold
sync:
  paths:
    - scaffold/docker-compose.yml
    - scaffold/traefik
    - scaffold/prometheus
    - scaffold/.env        # non-secret env (omit secret.env from sync)

# Optional extension scripts sourced at startup.
# They can define new subcommands as: ctrl_cmd_<name>() { ... }
extensions: []
  # - ext/my-custom-commands.sh
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

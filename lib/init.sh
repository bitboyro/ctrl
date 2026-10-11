#!/usr/bin/env bash
# init.sh — interactive ctrl.yaml wizard and PATH setup

ctrl_init() {
  local target_dir="${PWD}"
  local config_file="${target_dir}/ctrl.yaml"

  if [[ -f "${config_file}" ]]; then
    msg_warn "ctrl.yaml already exists at ${config_file}"
    printf 'Overwrite? [y/N] '
    read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { msg "Aborted."; return 0; }
  fi

  echo ""
  echo "${BOLD}ctrl init${RESET} — generating ctrl.yaml"
  echo ""

  printf 'Project name [%s]: ' "$(basename "${target_dir}")"
  read -r project_name
  [[ -n "${project_name}" ]] || project_name="$(basename "${target_dir}")"

  printf 'Image registry (e.g. docker.io/myorg): '
  read -r registry

  printf 'SSH host env var name [VM_HOST]: '
  read -r ssh_host_var
  [[ -n "${ssh_host_var}" ]] || ssh_host_var="VM_HOST"

  printf 'SSH user [root]: '
  read -r ssh_user
  [[ -n "${ssh_user}" ]] || ssh_user="root"

  printf 'Machine name [prod-vm]: '
  read -r machine_name
  [[ -n "${machine_name}" ]] || machine_name="prod-vm"

  printf 'Compose path on VM [/opt/%s/docker-compose.yml]: ' "${project_name}"
  read -r compose_path
  [[ -n "${compose_path}" ]] || compose_path="/opt/${project_name}/docker-compose.yml"

  # Everything below is written raw into YAML: accept plain values only
  ctrl_valid_name "${project_name}" "project name"
  ctrl_valid_name "${machine_name}" "machine name"
  ctrl_valid_name "${ssh_user}" "SSH user"
  [[ "${ssh_host_var}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Invalid env var name: '${ssh_host_var}'"
  [[ -z "${registry}" || "${registry}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$ ]] || fail "Invalid registry: '${registry}'"
  [[ "${compose_path}" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "Compose path must be an absolute path of plain characters: '${compose_path}'"

  cat > "${config_file}" << YAML
ctrl:
  version: "${CTRL_VERSION}"

meta:
  project: ${project_name}
  registry: ${registry:-docker.io/your-org}
  env_files: []

machines:
  default: ${machine_name}
  hosts:
    - name: ${machine_name}
      host: "\${${ssh_host_var}}"
      user: ${ssh_user}
      port: 22
      # cwd: /root

services: []

deployments:
  default: prod
  targets:
    - name: prod
      machine: ${machine_name}
      compose_path: ${compose_path}
      # cwd: $(dirname "${compose_path}")
      sync:
        paths: []

scripts: []

extensions: []
YAML

  msg_ok "Created ${config_file}"

  # ── .local/ setup ───────────────────────────────────────────────────────────
  local local_dir="${target_dir}/.local"
  mkdir -p "${local_dir}"
  if [[ ! -f "${local_dir}/.gitignore" ]]; then
    printf '*\n' > "${local_dir}/.gitignore"
  fi
  if [[ ! -f "${local_dir}/secrets.env.example" ]]; then
    cat > "${local_dir}/secrets.env.example" << 'ENV'
# Local secrets — copy to secrets.env and fill in values.
# secrets.env is auto-loaded by ctrl if .local/ exists.
# Reference these in ctrl.yaml using ${VAR} syntax.
#
# EXAMPLE_PASSWORD=
ENV
  fi
  msg_ok "Created .local/ (gitignored — secrets.env.example inside)"

  echo ""
  echo "Next steps:"
  echo "  1. Add services to ctrl.yaml"
  echo "  2. Set \${${ssh_host_var}} in your environment or .env"
  echo "  3. ctrl list"
  echo ""

  _ctrl_init_path_offer
}

_ctrl_init_path_offer() {
  local ctrl_path
  ctrl_path="$(command -v ctrl 2>/dev/null || true)"

  # Only offer PATH setup if ctrl is in ~/.local/bin and not in PATH yet
  if [[ -z "${ctrl_path}" ]]; then
    local local_bin="${HOME}/.local/bin"
    if [[ -f "${local_bin}/ctrl" ]]; then
      printf '%s is not in your PATH. Add %s to PATH? [y/N] ' "ctrl" "${local_bin}"
      read -r answer
      if [[ "${answer}" =~ ^[Yy]$ ]]; then
        _ctrl_add_to_path "${local_bin}"
      fi
    fi
  fi
}

_ctrl_add_to_path() {
  local bin_dir="$1"
  local export_line="export PATH=\"${bin_dir}:\$PATH\""
  local shell_rc=""

  if [[ -n "${ZSH_VERSION:-}" ]] || [[ "${SHELL}" == */zsh ]]; then
    shell_rc="${HOME}/.zshrc"
  else
    shell_rc="${HOME}/.bashrc"
  fi

  if grep -qF "${bin_dir}" "${shell_rc}" 2>/dev/null; then
    msg_warn "${bin_dir} already referenced in ${shell_rc}"
    return
  fi

  printf '\n# ctrl\n%s\n' "${export_line}" >> "${shell_rc}"
  msg_ok "Added ${bin_dir} to PATH in ${shell_rc}"
  msg "Restart your shell or run: source ${shell_rc}"
}

# ── upgrade ───────────────────────────────────────────────────────────────────
# Latest release from GitHub; shows the CHANGELOG between the running version
# and it; replaces a single-file install after SHA256 verification and a
# `version` sanity run. Source installs are pointed at install.sh instead.
# CTRL_REPO overrides the repository (and makes this testable).
ctrl_upgrade() {
  require_cmd curl
  local repo="${CTRL_REPO:-https://github.com/bitboyro/ctrl}"
  local api="${repo/https:\/\/github.com\//https://api.github.com/repos/}"
  local latest
  latest="$(curl -fsSL "${api}/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9.]*\)".*/\1/p' | head -1)"
  [[ -n "${latest}" ]] || fail "Could not determine the latest release from ${repo}"

  if ctrl_version_ge "${CTRL_VERSION}" "${latest}"; then
    msg_ok "ctrl v${CTRL_VERSION} is up to date (latest: v${latest})"
    return 0
  fi

  msg "ctrl v${CTRL_VERSION} → v${latest}"
  _ctrl_upgrade_changelog "${repo}" "${latest}"
  [[ "${CTRL_DRY_RUN}" == "1" ]] && return 0

  local self="${CTRL_BIN:-}"
  if ! declare -f _ctrl_embedded_bundled >/dev/null 2>&1 || [[ -z "${self}" || ! -f "${self}" ]]; then
    msg_warn "This is a source install (${CTRL_SELF_DIR:-?}) — upgrade it with:"
    echo "  curl -fsSL ${repo/github.com/raw.githubusercontent.com}/main/install.sh | bash -s -- v${latest}"
    return 0
  fi
  [[ -w "${self}" && -w "$(dirname "${self}")" ]] || fail "${self} is not writable — re-run with sudo, or reinstall with install.sh"

  if [[ -t 0 ]]; then
    local answer; printf 'Install v%s over %s? [y/N] ' "${latest}" "${self}"; read -r answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { msg "Aborted."; return 0; }
  fi

  local base="${repo}/releases/download/v${latest}"
  local tmp; tmp="$(mktemp "$(dirname "${self}")/.ctrl-upgrade.XXXXXX")"
  curl -fsSL "${base}/ctrl" -o "${tmp}" || { rm -f "${tmp}"; fail "Download failed: ${base}/ctrl"; }
  local want have
  want="$(curl -fsSL "${base}/ctrl.sha256" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${want}" ]]; then
    have="$( { sha256sum "${tmp}" 2>/dev/null || shasum -a 256 "${tmp}"; } | awk '{print $1}')"
    [[ "${want}" == "${have}" ]] || { rm -f "${tmp}"; fail "Checksum mismatch (want ${want}, got ${have}) — not installed"; }
    msg_ok "SHA256 verified"
  else
    msg_warn "No ctrl.sha256 published for v${latest} — skipping checksum verification"
  fi
  chmod +x "${tmp}"
  local got; got="$(bash "${tmp}" version 2>/dev/null || true)"
  [[ "${got}" == "ctrl v${latest}" ]] || { rm -f "${tmp}"; fail "Downloaded binary reports '${got:-nothing}', expected ctrl v${latest}"; }
  mv -f "${tmp}" "${self}"
  msg_ok "Upgraded to v${latest}"
}

# Print CHANGELOG sections newer than the running version, coloured by kind.
_ctrl_upgrade_changelog() {
  local repo="$1" latest="$2"
  local log; log="$(curl -fsSL "${repo/github.com/raw.githubusercontent.com}/v${latest}/CHANGELOG.md" 2>/dev/null || true)"
  [[ -n "${log}" ]] || { msg_warn "CHANGELOG not available"; return 0; }
  echo ""
  printf '%s\n' "${log}" | awk -v cur="${CTRL_VERSION}" -v g="${GREEN}" -v r="${RED}" -v y="${YELLOW}" -v b="${BOLD}" -v z="${RESET}" '
    function newer(v,   a, c, i, n) {           # v > cur ?
      n = split(v, a, "."); split(cur, c, ".")
      for (i = 1; i <= 3; i++) { if ((a[i]+0) > (c[i]+0)) return 1; if ((a[i]+0) < (c[i]+0)) return 0 }
      return 0
    }
    /^## \[/ { v = $2; gsub(/[\[\]]/, "", v); show = (v != "Unreleased" && newer(v)); if (show) print b $0 z; next }
    !show { next }
    /^### (Added)/                 { c = g }
    /^### (Removed|Security|Breaking)/ { c = r }
    /^### (Changed|Fixed|Deprecated)/  { c = y }
    /^### / { print c $0 z; next }
    { print }'
  echo ""
}

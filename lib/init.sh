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

  cat > "${config_file}" << YAML
ctrl:
  version: "1.0"

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

services: []

deployments:
  default: prod
  targets:
    - name: prod
      machine: ${machine_name}
      compose_path: ${compose_path}
      sync:
        paths: []

scripts: []

extensions: []
YAML

  msg_ok "Created ${config_file}"
  echo ""
  echo "Next steps:"
  echo "  1. Add services to ctrl.yaml"
  echo "  2. Set \${${ssh_host_var}} in your environment or scaffold/.env"
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

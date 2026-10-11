#!/usr/bin/env bash
# @name: install-docker
# @description: Install Docker Engine + compose plugin from the official repo (key fingerprint verified)
# @group: setup
# @requires: curl
# @os: linux darwin
# @sudo: yes
# @flags: --force --no-group
# @dry-run: yes
#
# Linux: Debian/Ubuntu/Raspbian (apt) and Fedora/RHEL/CentOS/Rocky/Alma (dnf)
# use download.docker.com; the repository key is checked against Docker's
# published fingerprint before it is trusted. Alpine uses apk. The invoking
# user is added to the docker group (--no-group to skip).
# macOS: Colima + the docker CLI via Homebrew (no Docker Desktop licence needed).
# Already installed → prints the version and exits (use --force to reinstall).
#
#   ctrl run install-docker --on staging
#   ctrl run install-docker            # this Mac
set -euo pipefail
# ctrl:lib

# Docker's release signing key — https://docs.docker.com/engine/install/
DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
force=0 group=1
for a in "$@"; do
  case "${a}" in
    --force)    force=1 ;;
    --no-group) group=0 ;;
    *)          die "Unknown argument: ${a}" ;;
  esac
done

if has docker && docker compose version >/dev/null 2>&1 && [[ "${force}" == "0" ]]; then
  ok "Docker is already installed: $(docker --version) · $(docker compose version --short 2>/dev/null || echo compose)"
  exit 0
fi

# Download the repo key to $1 and refuse it unless its fingerprint matches
fetch_verified_key() {
  local url="$1" dest="$2"
  run ${SUDO} curl -fsSL "${url}" -o "${dest}"
  [[ "${CTRL_DRY_RUN}" == "1" ]] && { echo "verify fingerprint of ${dest} == ${DOCKER_GPG_FPR}"; return 0; }
  local fpr
  if has gpg; then
    fpr="$(gpg --show-keys --with-colons "${dest}" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  else
    die "gpg is needed to verify Docker's repository key (install gnupg)"
  fi
  [[ "${fpr}" == "${DOCKER_GPG_FPR}" ]] || { ${SUDO} rm -f "${dest}"; die "Repository key fingerprint mismatch: got ${fpr:-none}"; }
  ok "Docker repository key verified (${fpr})"
}

add_user_to_group() {
  [[ "${group}" == "1" ]] || return 0
  local u="${SUDO_USER:-${USER:-$(id -un)}}"
  [[ "${u}" == "root" ]] && return 0
  run ${SUDO} usermod -aG docker "${u}"
  warn "${u} was added to the docker group — log out and back in (or run: newgrp docker)"
}

install_linux() {
  need_sudo
  local id; id="$(distro)"
  local codename; codename="$(distro_codename)"
  case "${id}" in
    ubuntu|debian|raspbian)
      local repo_id="${id}"; [[ "${id}" == "raspbian" ]] && repo_id=debian
      run ${SUDO} apt-get update -q
      run ${SUDO} apt-get install -y -q ca-certificates curl gnupg
      run ${SUDO} install -m 0755 -d /etc/apt/keyrings
      fetch_verified_key "https://download.docker.com/linux/${repo_id}/gpg" /etc/apt/keyrings/docker.asc
      run ${SUDO} chmod a+r /etc/apt/keyrings/docker.asc
      local arch_deb; arch_deb="$(dpkg --print-architecture 2>/dev/null || arch)"
      local line="deb [arch=${arch_deb} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_id} ${codename} stable"
      if [[ "${CTRL_DRY_RUN}" == "1" ]]; then echo "write /etc/apt/sources.list.d/docker.list: ${line}"
      else printf '%s\n' "${line}" | ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null; fi
      run ${SUDO} apt-get update -q
      run ${SUDO} apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    fedora|rhel|centos|rocky|almalinux)
      local repo="centos"; [[ "${id}" == "fedora" ]] && repo="fedora"; [[ "${id}" == "rhel" ]] && repo="rhel"
      run ${SUDO} dnf -y install dnf-plugins-core gnupg2
      fetch_verified_key "https://download.docker.com/linux/${repo}/gpg" /tmp/docker-repo.gpg
      run ${SUDO} rpm --import /tmp/docker-repo.gpg
      if dnf --version 2>/dev/null | head -1 | grep -q '^5\.'; then
        run ${SUDO} dnf config-manager addrepo --from-repofile="https://download.docker.com/linux/${repo}/docker-ce.repo"
      else
        run ${SUDO} dnf config-manager --add-repo "https://download.docker.com/linux/${repo}/docker-ce.repo"
      fi
      run ${SUDO} dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    alpine)
      run ${SUDO} apk add --no-cache docker docker-cli-compose
      run ${SUDO} rc-update add docker default
      run ${SUDO} service docker start
      add_user_to_group
      return
      ;;
    *)
      die "Unsupported distribution '${id:-unknown}' — see https://docs.docker.com/engine/install/"
      ;;
  esac
  run ${SUDO} systemctl enable --now docker
  add_user_to_group
}

install_darwin() {
  need_cmd brew
  run brew install colima docker docker-compose
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    echo "ln -sfn \$(brew --prefix)/opt/docker-compose/bin/docker-compose ~/.docker/cli-plugins/docker-compose"
  else
    mkdir -p "${HOME}/.docker/cli-plugins"
    ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" "${HOME}/.docker/cli-plugins/docker-compose"
  fi
  run colima start --cpu 2 --memory 4
}

case "$(os)" in
  linux)  install_linux ;;
  darwin) install_darwin ;;
  *)      die "install-docker supports Linux and macOS" ;;
esac

if [[ "${CTRL_DRY_RUN}" != "1" ]]; then
  ok "$(docker --version) · compose $(docker compose version --short 2>/dev/null || echo '?')"
fi

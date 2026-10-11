#!/usr/bin/env bash
# @name: add-swap
# @description: Add a swap file sized from RAM, persisted in fstab, low swappiness
# @group: setup
# @os: linux
# @sudo: yes
# @flags: --size 2G --file /swapfile --swappiness 10
# @dry-run: yes
#
# Default size: equal to RAM, at least 1G and at most 4G — enough to stop small
# VMs from OOM-killing builds. Does nothing when swap is already active.
#
#   ctrl run add-swap --on prod
#   ctrl run add-swap --on prod --size 8G
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
size="" file=/swapfile swappiness=10
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --size)       shift; size="${1:-}" ;;
    --file)       shift; file="${1:-}" ;;
    --swappiness) shift; swappiness="${1:-}" ;;
    *)            die "Unknown argument: $1" ;;
  esac
  shift
done
[[ "${swappiness}" =~ ^[0-9]+$ ]] || die "--swappiness must be 0-100"
[[ "${file}" == /* ]] || die "--file must be an absolute path"

active="$(swapon --show=NAME,SIZE --noheadings 2>/dev/null || true)"
if [[ -n "${active}" && "${CTRL_DRY_RUN}" != "1" ]]; then
  ok "Swap already active:"; echo "${active}"; exit 0
fi

if [[ -z "${size}" ]]; then
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 2097152)"
  gb=$(( (mem_kb + 1048575) / 1048576 ))
  (( gb < 1 )) && gb=1; (( gb > 4 )) && gb=4
  size="${gb}G"
fi
[[ "${size}" =~ ^[0-9]+[MG]$ ]] || die "--size must look like 2G or 512M"

need_sudo
say "Creating ${size} swap at ${file}"
mb="${size%?}"; [[ "${size: -1}" == "G" ]] && mb=$(( mb * 1024 ))
# fallocate is instant; some filesystems (e.g. older XFS/btrfs) need dd instead
run ${SUDO} fallocate -l "${size}" "${file}" || run ${SUDO} dd if=/dev/zero of="${file}" bs=1M count="${mb}"
run ${SUDO} chmod 600 "${file}"
run ${SUDO} mkswap "${file}"
run ${SUDO} swapon "${file}"

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  echo "append to /etc/fstab: ${file} none swap sw 0 0"
  echo "write /etc/sysctl.d/99-ctrl-swap.conf: vm.swappiness=${swappiness}"
else
  grep -qE "^${file}[[:space:]]" /etc/fstab || printf '%s none swap sw 0 0\n' "${file}" | ${SUDO} tee -a /etc/fstab >/dev/null
  printf 'vm.swappiness=%s\n' "${swappiness}" | ${SUDO} tee /etc/sysctl.d/99-ctrl-swap.conf >/dev/null
fi
run ${SUDO} sysctl -w "vm.swappiness=${swappiness}"
[[ "${CTRL_DRY_RUN}" == "1" ]] || { ok "Swap on:"; swapon --show; }

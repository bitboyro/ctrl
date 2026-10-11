#!/usr/bin/env bash
# @name: dclean
# @description: Show what Docker can reclaim, then prune it (asks first)
# @group: docker
# @requires: docker
# @flags: --images (all unused, not just dangling) --volumes --builder
# @dry-run: yes
#
# Default: stopped containers, dangling images, unused networks, build cache.
# --images also removes every image no container uses; --volumes removes
# unused volumes (data loss — asked separately).
#
#   ctrl run dclean
#   ctrl run dclean --images --on @web --yes
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
all=0 volumes=0
for a in "$@"; do
  case "${a}" in
    --images)  all=1 ;;
    --volumes) volumes=1 ;;
    --builder) ;;   # build cache is always included
    *)         die "Unknown argument: ${a}" ;;
  esac
done

say "Docker disk usage"
if [[ "${CTRL_DRY_RUN}" != "1" ]]; then
  docker system df
  echo ""
fi

args=(system prune -f)
[[ "${all}" == "1" ]] && args+=(--all)
if [[ "${volumes}" == "1" ]]; then
  confirm "Also delete unused VOLUMES (their data is gone for good)?" && args+=(--volumes) || warn "Keeping volumes"
fi

what="dangling images only"; [[ "${all}" == "1" ]] && what="all unused images"
confirm "Prune stopped containers, unused networks, build cache and ${what}?" || { warn "Nothing removed"; exit 0; }
run docker "${args[@]}"
run docker builder prune -f
[[ "${CTRL_DRY_RUN}" == "1" ]] || { echo ""; docker system df; }

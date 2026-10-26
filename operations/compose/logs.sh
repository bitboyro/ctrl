#!/usr/bin/env bash
set -euo pipefail
compose=(docker compose -f "${COMPOSE_FILE:-docker-compose.yml}")
service=()
[[ -z "${CTRL_PARAM_SERVICE:-}" ]] || service=("${CTRL_PARAM_SERVICE}")

flags=(--tail "${CTRL_PARAM_LINES}")
[[ "${CTRL_PARAM_FOLLOW}" != true ]] || flags+=(--follow)
"${compose[@]}" logs "${flags[@]}" "${service[@]+"${service[@]}"}"

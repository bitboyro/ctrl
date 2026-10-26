#!/usr/bin/env bash
set -euo pipefail
compose=(docker compose -f "${COMPOSE_FILE:-docker-compose.yml}")
service=()
[[ -z "${CTRL_PARAM_SERVICE:-}" ]] || service=("${CTRL_PARAM_SERVICE}")
"${compose[@]}" restart "${service[@]}"

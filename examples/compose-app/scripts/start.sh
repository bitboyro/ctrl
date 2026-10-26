#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
export APP_TAG="${CTRL_PARAM_TAG}"
exec docker compose -f docker-compose.yml up -d --no-build api

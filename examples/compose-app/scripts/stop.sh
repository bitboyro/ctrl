#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
exec docker compose -f docker-compose.yml down

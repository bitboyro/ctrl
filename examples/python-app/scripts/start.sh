#!/usr/bin/env bash
set -euo pipefail
exec python3 "${CTRL_PROJECT_DIR}/app/server.py" --port "${CTRL_PARAM_PORT}"

#!/usr/bin/env bash
set -euo pipefail
exec node "${CTRL_PROJECT_DIR}/app.js" "${CTRL_PARAM_PORT}"

#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
exec node test.js

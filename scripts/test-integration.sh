#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
export CTRL_REAL_INTEGRATION=1
exec python3 -m unittest discover -s tests/integration -v

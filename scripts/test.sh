#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
exec python3 -m unittest discover -s tests/runner -v

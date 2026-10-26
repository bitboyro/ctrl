#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
# Keep test bytecode out of the project tree.
export PYTHONDONTWRITEBYTECODE=1
exec python3 -m unittest discover -s . -p test_app.py -v

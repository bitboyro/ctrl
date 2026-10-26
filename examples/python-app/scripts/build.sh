#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
mkdir -p .local/build
python3 -m zipapp app -o .local/build/demo.pyz
printf 'Built .local/build/demo.pyz\n'

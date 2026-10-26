#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
mkdir -p .local/build
cp app.js package.json .local/build/
printf 'Prepared .local/build/app.js and package.json\n'

#!/usr/bin/env bash
set -euo pipefail
artifact="${CTRL_PROJECT_DIR}/.local/build/demo.jar"
[[ -f "${artifact}" ]] || { echo 'Run ctrl build --yes first' >&2; exit 1; }
exec java -jar "${artifact}" "${CTRL_PARAM_NAME}"

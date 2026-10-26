#!/usr/bin/env bash
# Source checkout entry point. Release builds are self-contained Python zipapps.
set -euo pipefail
CTRL_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${CTRL_SOURCE_DIR}/src/ctrl.py" "$@"

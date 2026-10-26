#!/usr/bin/env bash
set -euo pipefail
CTRL_BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${CTRL_BUILD_DIR}/scripts/build.py"

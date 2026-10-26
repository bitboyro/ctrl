#!/usr/bin/env bash
set -euo pipefail
cd "${CTRL_PROJECT_DIR}"
exec mvn -B -ntp "-Dmaven.repo.local=${CTRL_PROJECT_DIR}/.local/m2" -DskipTests package

#!/usr/bin/env bash
set -euo pipefail
curl --fail --silent --show-error --max-time 10 "${APP_URL}/health"

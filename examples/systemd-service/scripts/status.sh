#!/usr/bin/env bash
set -euo pipefail
[[ "${CTRL_REMOTE}" == 1 ]] || { echo 'Select the configured remote host with --on demo' >&2; exit 1; }
exec systemctl status --no-pager -- "${CTRL_PARAM_UNIT}"

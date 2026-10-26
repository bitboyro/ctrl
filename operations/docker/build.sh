#!/usr/bin/env bash
set -euo pipefail
args=(build -f "${CTRL_PARAM_DOCKERFILE}" -t "${CTRL_PARAM_IMAGE}" "${CTRL_PARAM_CONTEXT}")
docker "${args[@]}"
[[ "${CTRL_PARAM_PUSH}" != true ]] || docker push "${CTRL_PARAM_IMAGE}"

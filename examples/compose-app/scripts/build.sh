#!/usr/bin/env bash
set -euo pipefail
# Unlike ctrl 0.4's framework matrix, build details belong to the project.
image="example/${CTRL_PARAM_SERVICE}:${CTRL_PARAM_TAG}"
docker build -t "${image}" "${CTRL_PROJECT_DIR}/${CTRL_PARAM_SERVICE}"
[[ "${CTRL_PARAM_PUSH}" != true ]] || docker push "${image}"

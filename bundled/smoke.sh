#!/usr/bin/env bash
# @name: smoke
# @description: Run the smoke-test scripts declared in services[].smoke_tests
# @group: project
# @tags: smoke
# @requires: yq
# @flags: [svc|all …]
# @remote: no
# @dry-run: yes
#
# Each services[].smoke_tests entry is a script name, run with `ctrl run`, so
# it can be a project script or a bundled one. Exit code is non-zero if any fails.
#
#   ctrl run smoke            # every service
#   ctrl run smoke api worker
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
cfg="${CTRL_CONFIG_MERGED:-${CTRL_CONFIG_FILE:-}}"
[[ -n "${cfg}" && -f "${cfg}" ]] || die "smoke needs a ctrl.yaml with services[].smoke_tests"
ctrl="${CTRL_BIN:-ctrl}"

svcs=()
if [[ "$#" -eq 0 || "${1:-}" == "all" ]]; then
  while IFS= read -r s; do [[ -n "${s}" ]] && svcs+=("${s}"); done < <(yq '.services[].name' "${cfg}")
else
  for s in "$@"; do
    IFS=',' read -r -a parts <<< "${s}"
    svcs+=("${parts[@]}")
  done
fi

found=0 failed=0
for svc in "${svcs[@]}"; do
  [[ "${svc}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Invalid service name: '${svc}'"
  exists="$(CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .name' "${cfg}")"
  [[ -n "${exists}" ]] || die "Unknown service: ${svc}"
  while IFS= read -r test; do
    [[ -z "${test}" || "${test}" == "null" ]] && continue
    found=1
    say "Smoke test [${svc}]: ${test}"
    dry=(); [[ "${CTRL_DRY_RUN}" == "1" ]] && dry=(-n)
    if "${ctrl}" --config "${CTRL_CONFIG_FILE}" run "${test}" "${dry[@]+"${dry[@]}"}"; then
      ok "${svc}: ${test}"
    else
      warn "${svc}: ${test} failed"; failed=1
    fi
  done < <(CTRL_Q="${svc}" yq '.services[] | select(.name == strenv(CTRL_Q)) | .smoke_tests[]? // ""' "${cfg}")
done

[[ "${found}" == "1" ]] || warn "No smoke tests defined for: ${svcs[*]}"
exit "${failed}"

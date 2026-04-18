#!/usr/bin/env bash
# audit.sh — history display, journal helpers (journal_entry is in core.sh)

show_history() {
  local lines="${1:-20}"
  [[ -f "${CTRL_JOURNAL}" ]] || { msg_warn "No journal found at ${CTRL_JOURNAL}"; return 0; }
  require_cmd jq
  tail -n "${lines}" "${CTRL_JOURNAL}" | jq -r \
    '"\(.ts)  \(.command | @sh)  svcs=\(.services)  exit=\(.exit_code)  \(.duration_s)s"'
}

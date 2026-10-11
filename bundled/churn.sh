#!/usr/bin/env bash
# @name: churn
# @description: Git change activity — lines added/removed per author or file, and hotspot files
# @group: dev
# @requires: git
# @flags: --since '30 days' --by author|file|hotspot --top 15 [paths…]
# @dry-run: yes
#
# hotspot ranks files by how often they changed × their current size — the
# places where bugs and merge conflicts concentrate.
#
#   ctrl run churn                        # authors, last 30 days
#   ctrl run churn --by file --since '6 months'
#   ctrl run churn --by hotspot --top 10
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
since="30 days" by=author top=15 paths=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --since) shift; since="${1:-30 days}" ;;
    --by)    shift; by="${1:-author}" ;;
    --top)   shift; top="${1:-15}" ;;
    -*)      die "Unknown flag: $1" ;;
    *)       paths+=("$1") ;;
  esac
  shift
done
[[ "${by}" =~ ^(author|file|hotspot)$ ]] || die "--by must be author, file or hotspot"
[[ "${top}" =~ ^[0-9]+$ ]] || die "--top must be a number"
[[ "${since}" =~ ^[A-Za-z0-9\ .:-]+$ ]] || die "--since must look like '30 days' or 2026-01-01"
git rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository: ${PWD}"

log_cmd=(git log --no-merges --since="${since} ago" --numstat --format='@%aN' -- "${paths[@]+"${paths[@]}"}")
[[ "${since}" =~ ^[0-9]{4}- ]] && log_cmd=(git log --no-merges --since="${since}" --numstat --format='@%aN' -- "${paths[@]+"${paths[@]}"}")
if [[ "${CTRL_DRY_RUN}" == "1" ]]; then printf '%s\n' "$(printf '%q ' "${log_cmd[@]}")"; exit 0; fi

log="$("${log_cmd[@]}")"
[[ -n "${log}" ]] || { warn "No commits since ${since}"; exit 0; }
commits="$(grep -c '^@' <<< "${log}" || true)"
say "${commits} commits since ${since}${paths[*]:+ in ${paths[*]}}"

bar_awk='function bar(v, m,   w, s, i) { w = (m > 0) ? int(v * 20 / m + 0.5) : 0; s = ""; for (i = 0; i < 20; i++) s = s (i < w ? "█" : "·"); return s }'

case "${by}" in
  author)
    printf '%s%-24s %8s %9s %9s  %s%s\n' "${_c_b}" "AUTHOR" "COMMITS" "ADDED" "REMOVED" "" "${_c_0}"
    awk -F'\t' -v g="${_c_g}" -v r="${_c_r}" -v z="${_c_0}" "${bar_awk}"'
      /^@/ { a = substr($0, 2); n[a]++; next }
      NF == 3 && $1 != "-" { add[a] += $1; del[a] += $2 }
      END { for (k in n) if (n[k] > m) m = n[k]
            for (k in n) printf "%s\t%d\t%d\t%d\t%s\n", k, n[k], add[k], del[k], bar(n[k], m) }' <<< "${log}" \
      | sort -t$'\t' -k2,2nr | head -n "${top}" \
      | awk -F'\t' -v g="${_c_g}" -v r="${_c_r}" -v z="${_c_0}" '{ printf "%-24s %8d %s%+9d%s %s%9d%s  %s\n", substr($1,1,24), $2, g, $3, z, r, -$4, z, $5 }'
    ;;
  file)
    printf '%s%-52s %7s %9s %9s%s\n' "${_c_b}" "FILE" "CHANGES" "ADDED" "REMOVED" "${_c_0}"
    awk -F'\t' 'NF == 3 && $1 != "-" { n[$3]++; add[$3] += $1; del[$3] += $2 }
      END { for (k in n) printf "%s\t%d\t%d\t%d\n", k, n[k], add[k], del[k] }' <<< "${log}" \
      | sort -t$'\t' -k2,2nr -k3,3nr | head -n "${top}" \
      | awk -F'\t' -v g="${_c_g}" -v r="${_c_r}" -v z="${_c_0}" '{ f=$1; if (length(f) > 52) f = "…" substr(f, length(f)-50); printf "%-52s %7d %s%+9d%s %s%9d%s\n", f, $2, g, $3, z, r, -$4, z }'
    ;;
  hotspot)
    printf '%s%-52s %7s %7s %8s  %s%s\n' "${_c_b}" "FILE" "CHANGES" "LINES" "SCORE" "" "${_c_0}"
    awk -F'\t' 'NF == 3 && $1 != "-" { n[$3]++ } END { for (k in n) printf "%s\t%d\n", k, n[k] }' <<< "${log}" \
      | while IFS=$'\t' read -r f n; do
          [[ -f "${f}" ]] || continue
          lines="$(wc -l < "${f}" | tr -d ' ')"
          printf '%s\t%d\t%d\t%d\n' "${f}" "${n}" "${lines}" "$(( n * lines ))"
        done \
      | sort -t$'\t' -k4,4nr | head -n "${top}" \
      | awk -F'\t' -v y="${_c_y}" -v z="${_c_0}" "${bar_awk}"'
          NR == 1 { m = $4 } { f=$1; if (length(f) > 52) f = "…" substr(f, length(f)-50)
                    printf "%-52s %7d %7d %8d  %s%s%s\n", f, $2, $3, $4, y, bar($4, m), z }'
    ;;
esac

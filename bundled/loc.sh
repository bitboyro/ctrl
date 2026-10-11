#!/usr/bin/env bash
# @name: loc
# @description: Lines of code by language — code, comments, blanks; or by folder, or biggest files
# @group: dev
# @flags: [paths…] --by lang|dir|file --top 15 --json
# @dry-run: yes
#
# Pure awk, no dependencies: files under the current directory from
# `git ls-files` (or find, skipping
# vendored/build dirs), language by extension, line comments per language and
# /* … */ blocks for C-like ones. Works on --on hosts too.
#
#   ctrl run loc                   # by language
#   ctrl run loc --by dir          # by top-level folder
#   ctrl run loc --by file --top 10
#   ctrl run loc src lib --json
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
by=lang top=15 json=0 paths=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --by)   shift; by="${1:-lang}" ;;
    --top)  shift; top="${1:-15}" ;;
    --json) json=1 ;;
    -*)     die "Unknown flag: $1" ;;
    *)      paths+=("$1") ;;
  esac
  shift
done
[[ "${by}" =~ ^(lang|dir|file)$ ]] || die "--by must be lang, dir or file"
[[ "${top}" =~ ^[0-9]+$ ]] || die "--top must be a number"

if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
  echo "git ls-files ${paths[*]:-} | awk (count code/comment/blank by ${by})"
  exit 0
fi

PRUNE='node_modules|vendor|dist|build|target|\.venv|venv|__pycache__|\.git|\.local|\.terraform|\.next'
files() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    { git ls-files -- "${paths[@]+"${paths[@]}"}"; git ls-files --others --exclude-standard -- "${paths[@]+"${paths[@]}"}"; } | sort -u
  else
    find "${paths[@]:-.}" -type f 2>/dev/null | sed 's|^\./||' | grep -Ev "(^|/)(${PRUNE})/" || true
  fi | while IFS= read -r f; do if [[ -f "${f}" ]]; then printf "%s\n" "${f}"; fi; done
}

# One awk pass over every file: per-file language, code, comment, blank.
counts="$(files | tr '\n' '\0' | xargs -0 awk '
  function lang(f,   b, e) {
    b = f; sub(/.*\//, "", b)
    if (b ~ /^(Dockerfile|Containerfile)/) return "Dockerfile"
    if (b == "Makefile" || b ~ /\.mk$/)    return "Make"
    e = b; if (e !~ /\./) return ""; sub(/.*\./, "", e); e = tolower(e)
    if (e == "sh" || e == "bash" || e == "bats" || e == "zsh") return "Shell"
    if (e == "py") return "Python";          if (e == "go") return "Go"
    if (e == "java") return "Java";          if (e == "kt" || e == "kts") return "Kotlin"
    if (e == "js" || e == "mjs" || e == "cjs" || e == "jsx") return "JavaScript"
    if (e == "ts" || e == "tsx") return "TypeScript"
    if (e == "rs") return "Rust";            if (e == "rb") return "Ruby"
    if (e == "c" || e == "h") return "C";    if (e == "cpp" || e == "cc" || e == "hpp") return "C++"
    if (e == "cs") return "C#";              if (e == "swift") return "Swift"
    if (e == "php") return "PHP";            if (e == "sql") return "SQL"
    if (e == "html" || e == "htm") return "HTML"
    if (e == "css" || e == "scss") return "CSS"
    if (e == "yml" || e == "yaml") return "YAML"
    if (e == "json") return "JSON";          if (e == "toml") return "TOML"
    if (e == "xml") return "XML";            if (e == "md") return "Markdown"
    if (e == "tf") return "Terraform";       if (e == "lua") return "Lua"
    return ""
  }
  function style(l) {   # comment style
    if (l ~ /^(Shell|Python|Ruby|YAML|TOML|Make|Dockerfile|Terraform)$/) return "hash"
    if (l ~ /^(Go|Java|Kotlin|JavaScript|TypeScript|Rust|C|C\+\+|C#|Swift|PHP|CSS)$/) return "c"
    if (l == "SQL" || l == "Lua") return "dash"
    if (l == "HTML" || l == "XML" || l == "Markdown") return "xml"
    return "none"
  }
  function flush() { if (cur != "" && L != "") printf "%s\t%s\t%d\t%d\t%d\n", cur, L, code, com, blank }
  FNR == 1 { flush(); cur = FILENAME; L = lang(cur); S = style(L); code = com = blank = 0; inblock = 0
             if (L == "" ) { nextfile } }
  {
    line = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", line)
    if (line == "") { blank++; next }
    if (inblock) { com++; if (line ~ /\*\/|-->/) inblock = 0; next }
    if (S == "hash" && line ~ /^#/ && !(FNR == 1 && line ~ /^#!/)) { com++; next }
    if (S == "dash" && line ~ /^--/) { com++; next }
    if (S == "c" && line ~ /^\/\//) { com++; next }
    if (S == "c" && line ~ /^\/\*/) { com++; if (line !~ /\*\//) inblock = 1; next }
    if (S == "xml" && L != "Markdown" && line ~ /^<!--/) { com++; if (line !~ /-->/) inblock = 1; next }
    code++
  }
  END { flush() }' 2>/dev/null || true)"

[[ -n "${counts}" ]] || { warn "No source files found"; exit 0; }

# Aggregate: key<TAB>files<TAB>code<TAB>comment<TAB>blank
case "${by}" in
  lang) agg="$(awk -F'\t' '{k=$2; f[k]++; c[k]+=$3; m[k]+=$4; b[k]+=$5} END{for(k in f) printf "%s\t%d\t%d\t%d\t%d\n",k,f[k],c[k],m[k],b[k]}' <<< "${counts}" | sort -t$'\t' -k3,3nr)" ;;
  dir)  agg="$(awk -F'\t' '{k=$1; if (k ~ /\//) sub(/\/.*/, "/", k); else k="."; f[k]++; c[k]+=$3; m[k]+=$4; b[k]+=$5} END{for(k in f) printf "%s\t%d\t%d\t%d\t%d\n",k,f[k],c[k],m[k],b[k]}' <<< "${counts}" | sort -t$'\t' -k3,3nr)" ;;
  file) agg="$(awk -F'\t' '{printf "%s\t%s\t%d\t%d\t%d\n",$1,$2,$3,$4,$5}' <<< "${counts}" | sort -t$'\t' -k3,3nr | head -n "${top}")" ;;
esac

if [[ "${json}" == "1" ]]; then
  if [[ "${by}" == "file" ]]; then
    awk -F'\t' 'BEGIN{printf "["} {printf "%s{\"file\":\"%s\",\"language\":\"%s\",\"code\":%d,\"comment\":%d,\"blank\":%d}", (NR>1?",":""), $1,$2,$3,$4,$5} END{print "]"}' <<< "${agg}"
  else
    awk -F'\t' -v key="${by}" 'BEGIN{printf "["} {printf "%s{\"%s\":\"%s\",\"files\":%d,\"code\":%d,\"comment\":%d,\"blank\":%d}", (NR>1?",":""), key,$1,$2,$3,$4,$5} END{print "]"}' <<< "${agg}"
  fi
  exit 0
fi

total_code="$(awk -F'\t' '{s+=$3} END{print s+0}' <<< "${counts}")"
if [[ "${by}" == "file" ]]; then
  printf '%s%-52s %-11s %7s %7s %7s%s\n' "${_c_b}" "FILE" "LANGUAGE" "CODE" "COMMENT" "BLANK" "${_c_0}"
  awk -F'\t' '{f=$1; if (length(f) > 52) f = "…" substr(f, length(f)-50); printf "%-52s %-11s %7d %7d %7d\n", f, $2, $3, $4, $5}' <<< "${agg}"
else
  label="LANGUAGE"; [[ "${by}" == "dir" ]] && label="FOLDER"
  printf '%s%-16s %6s %8s %8s %8s  %-22s%s\n' "${_c_b}" "${label}" "FILES" "CODE" "COMMENT" "BLANK" "SHARE" "${_c_0}"
  awk -F'\t' -v t="${total_code}" -v g="${_c_g}" -v d="${_c_d}" -v z="${_c_0}" '{
      p = (t > 0) ? $3 * 100 / t : 0; w = int(p / 5 + 0.5); bar = ""
      for (i = 0; i < 20; i++) bar = bar (i < w ? "█" : "·")
      printf "%-16s %6d %8d %8d %8d  %s%s%s %4.1f%%\n", $1, $2, $3, $4, $5, g, bar, z, p }' <<< "${agg}"
  awk -F'\t' -v b="${_c_b}" -v z="${_c_0}" '{f+=1; c+=$3; m+=$4; k+=$5} END{printf "%s%-16s %6d %8d %8d %8d%s\n", b, "total", f, c, m, k, z}' <<< "${counts}"
fi

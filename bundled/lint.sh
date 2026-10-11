#!/usr/bin/env bash
# @name: lint
# @description: Lint everything in the project — detects file types, runs the right linter for each
# @group: dev
# @remote: no
# @flags: [paths…] --changed [REF] --fix --only shell,yaml,… --list
# @dry-run: yes
#
# Files under the current directory come from `git ls-files` (or find,
# skipping vendored/build dirs).
# Linters run only when installed; missing ones are listed with how to get them.
#
#   kind        linter (fallback)            --fix
#   shell       shellcheck                   shfmt -w
#   dockerfile  hadolint
#   yaml        yamllint (yq parse)
#   actions     actionlint                   (.github/workflows)
#   json        jq parse
#   python      ruff (flake8)                ruff --fix
#   js/ts       eslint via npx (only with an eslint config)   eslint --fix
#   go          gofmt -l + go vet            gofmt -w
#   markdown    markdownlint (only when installed)
#   ctrl        ctrl check (when a ctrl.yaml is present)
#
#   ctrl run lint                     # whole project
#   ctrl run lint --changed           # only files changed vs main (or HEAD)
#   ctrl run lint --only shell --fix
#   ctrl run lint --list              # what would run, and what is missing
set -euo pipefail
# ctrl:lib

common_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
paths=() changed="" fix=0 only="" list=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --changed)
      changed="auto"
      if [[ -n "${2:-}" && "${2}" != -* ]]; then changed="$2"; shift; fi ;;
    --fix)  fix=1 ;;
    --only) shift; only=",${1:-},"; only="${only// /}" ;;
    --list) list=1 ;;
    -*)     die "Unknown flag: $1" ;;
    *)      paths+=("$1") ;;
  esac
  shift
done

# Works on the current directory (like git): run it where you want it to look.

# ── file discovery ────────────────────────────────────────────────────────────
PRUNE='node_modules|vendor|dist|build|target|\.venv|venv|__pycache__|\.git|\.local|\.terraform|\.next'
list_files() {
  if [[ -n "${changed}" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    local base="${changed}"
    if [[ "${base}" == "auto" ]]; then
      base="$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo HEAD)"
    fi
    { git diff --name-only --diff-filter=ACMR "${base}" -- "${paths[@]+"${paths[@]}"}"
      git ls-files --others --exclude-standard -- "${paths[@]+"${paths[@]}"}"; } | sort -u
  elif git rev-parse --git-dir >/dev/null 2>&1; then
    { git ls-files -- "${paths[@]+"${paths[@]}"}"; git ls-files --others --exclude-standard -- "${paths[@]+"${paths[@]}"}"; } | sort -u
  else
    find "${paths[@]:-.}" -type f 2>/dev/null | sed 's|^\./||' | grep -Ev "(^|/)(${PRUNE})/" || true
  fi | while IFS= read -r f; do if [[ -f "${f}" ]]; then printf "%s\n" "${f}"; fi; done
}

all="$(list_files)"
[[ -n "${all}" ]] || { warn "No files to lint"; exit 0; }

# kind of one file: by name, extension, then shebang
kind_of() {
  local f="$1" b; b="$(basename "$f")"
  case "${f}" in .github/workflows/*.yml|.github/workflows/*.yaml) echo actions; return ;; esac
  case "${b}" in
    Dockerfile|Dockerfile.*|*.Dockerfile|Containerfile) echo dockerfile; return ;;
    ctrl.yaml) echo ctrl; return ;;
  esac
  case "${b}" in
    *.sh|*.bash|*.bats) echo shell ;;
    *.yml|*.yaml)       echo yaml ;;
    *.json)             echo json ;;
    *.py)               echo python ;;
    *.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs) echo js ;;
    *.go)               echo go ;;
    *.md)               echo markdown ;;
    *.*)                echo other ;;
    *) if head -c 64 "${f}" 2>/dev/null | head -1 | grep -qE '^#!.*\b(ba)?sh\b'; then echo shell; else echo other; fi ;;
  esac
}

# Group files by kind into temp lists (bash 3.2: no associative arrays)
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
while IFS= read -r f; do
  k="$(kind_of "${f}")"
  [[ "${k}" == other ]] && continue
  [[ -z "${only}" || "${only}" == *",${k},"* ]] || continue
  printf '%s\n' "${f}" >> "${tmp}/${k}"
done <<< "${all}"
# ctrl.yaml is also YAML
[[ -f "${tmp}/ctrl" && ( -z "${only}" || "${only}" == *",yaml,"* ) ]] && cat "${tmp}/ctrl" >> "${tmp}/yaml"

files_of() { [[ -f "${tmp}/$1" ]] && cat "${tmp}/$1"; }
count_of() { [[ -f "${tmp}/$1" ]] && wc -l < "${tmp}/$1" | tr -d ' ' || echo 0; }

hint() {  # hint <tool>
  local brew="$1" apt="$1"
  case "$1" in
    hadolint) apt="(download from github.com/hadolint/hadolint/releases)" ;;
    actionlint) apt="(go install github.com/rhysd/actionlint/cmd/actionlint@latest)" ;;
    markdownlint) brew="markdownlint-cli"; apt="(npm i -g markdownlint-cli)" ;;
    ruff) apt="(pipx install ruff)" ;;
  esac
  if [[ "$(os)" == darwin ]]; then echo "brew install ${brew}"; else echo "apt-get install ${apt}"; fi
}

# ── plan: kind → the command that will run ────────────────────────────────────
results=()   # "kind|tool|files|status"
failed=0
missing=()

# run_linter <kind> <tool> <cmd…>   (the file list is appended by xargs)
run_linter() {
  local k="$1" tool="$2"; shift 2
  local n; n="$(count_of "${k}")"
  if [[ "${list}" == "1" ]]; then results+=("${k}|${tool}|${n}|would run"); return 0; fi
  if [[ "${CTRL_DRY_RUN}" == "1" ]]; then
    local q; q="$(printf '%q ' "$@")"
    printf '%s <%s %s files>\n' "${q% }" "${k}" "${n}"
    results+=("${k}|${tool}|${n}|dry-run"); return 0
  fi
  say "${tool} (${n} ${k} files)"
  if files_of "${k}" | tr '\n' '\0' | xargs -0 "$@"; then
    results+=("${k}|${tool}|${n}|ok")
  else
    results+=("${k}|${tool}|${n}|FAILED"); failed=1
  fi
}

skip() { results+=("$1|$2|$(count_of "$1")|missing: $(hint "$2")"); missing+=("$2"); }

if [[ -f "${tmp}/shell" ]]; then
  if has shellcheck; then run_linter shell shellcheck shellcheck -S warning -x
  else skip shell shellcheck; fi
  if [[ "${fix}" == "1" ]]; then
    if has shfmt; then run_linter shell shfmt shfmt -w -i 2 -ci -bn; else skip shell shfmt; fi
  fi
fi

if [[ -f "${tmp}/dockerfile" ]]; then
  if has hadolint; then run_linter dockerfile hadolint hadolint; else skip dockerfile hadolint; fi
fi

if [[ -f "${tmp}/yaml" ]]; then
  if has yamllint; then
    run_linter yaml yamllint yamllint -d '{extends: relaxed, rules: {line-length: disable}}'
  elif has yq; then
    run_linter yaml "yq (parse)" sh -c 'for f; do yq e "true" "$f" >/dev/null || { echo "invalid YAML: $f" >&2; exit 1; }; done' _
  else skip yaml yamllint; fi
fi

if [[ -f "${tmp}/actions" ]]; then
  if has actionlint; then run_linter actions actionlint actionlint; else skip actions actionlint; fi
fi

if [[ -f "${tmp}/json" ]]; then
  if has jq; then
    run_linter json "jq (parse)" sh -c 'for f; do jq empty "$f" 2>/dev/null || { echo "invalid JSON: $f" >&2; exit 1; }; done' _
  else skip json jq; fi
fi

if [[ -f "${tmp}/python" ]]; then
  if has ruff; then
    if [[ "${fix}" == "1" ]]; then run_linter python ruff ruff check --fix; else run_linter python ruff ruff check; fi
  elif has flake8; then run_linter python flake8 flake8
  else skip python ruff; fi
fi

if [[ -f "${tmp}/js" ]]; then
  if ls .eslintrc* eslint.config.* >/dev/null 2>&1 || grep -q '"eslint"' package.json 2>/dev/null; then
    if has npx; then
      if [[ "${fix}" == "1" ]]; then run_linter js eslint npx --no-install eslint --fix; else run_linter js eslint npx --no-install eslint; fi
    else skip js eslint; fi
  fi
fi

if [[ -f "${tmp}/go" ]]; then
  if has gofmt; then
    if [[ "${fix}" == "1" ]]; then run_linter go gofmt gofmt -w
    else run_linter go "gofmt -l" sh -c 'out="$(gofmt -l "$@")"; [ -z "$out" ] || { echo "needs gofmt:"; echo "$out"; exit 1; }' _; fi
    [[ -f go.mod && "${list}" != "1" && "${CTRL_DRY_RUN}" != "1" ]] && { say "go vet ./..."; go vet ./... && results+=("go|go vet|-|ok") || { results+=("go|go vet|-|FAILED"); failed=1; }; }
  else skip go gofmt; fi
fi

if [[ -f "${tmp}/markdown" ]] && has markdownlint; then
  run_linter markdown markdownlint markdownlint --disable MD013
fi

if [[ -f "${tmp}/ctrl" ]] && [[ -n "${CTRL_BIN:-}" && -x "${CTRL_BIN}" ]]; then
  if [[ "${list}" == "1" || "${CTRL_DRY_RUN}" == "1" ]]; then results+=("ctrl|ctrl check|1|would run")
  else
    say "ctrl check"
    if "${CTRL_BIN}" check; then results+=("ctrl|ctrl check|1|ok"); else results+=("ctrl|ctrl check|1|FAILED"); failed=1; fi
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
printf '%s%-11s %-13s %6s  %s%s\n' "${_c_b}" "KIND" "LINTER" "FILES" "RESULT" "${_c_0}"
for r in "${results[@]+"${results[@]}"}"; do
  IFS='|' read -r k tool n st <<< "${r}"
  c="${_c_0}"
  case "${st}" in ok) c="${_c_g}" ;; FAILED) c="${_c_r}" ;; missing*) c="${_c_y}" ;; esac
  printf '%-11s %-13s %6s  %s%s%s\n' "${k}" "${tool}" "${n}" "${c}" "${st}" "${_c_0}"
done
[[ "${#results[@]}" -gt 0 ]] || say "Nothing lintable found"
exit "${failed}"

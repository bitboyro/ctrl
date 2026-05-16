#!/usr/bin/env bash
# tests/helpers/random.bash — random generators for property-based tests.

# Random lowercase alpha string of length $1 (default 8).
rand_word() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c "${len}"
}

# Random valid script name (lowercase, hyphen-friendly, never empty).
rand_script_name() {
  printf '%s-%s' "$(rand_word 4)" "$(rand_word 4)"
}

# Random uppercase env var name.
rand_env_name() {
  local len="${1:-8}"
  LC_ALL=C tr -dc 'A-Z' </dev/urandom | head -c "${len}"
}

# Random env var value: printable alphanumeric.
rand_env_value() {
  local len="${1:-12}"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
}

# Random semver-ish version (X.Y.Z).
rand_version() {
  printf '%d.%d.%d' "$((RANDOM % 10))" "$((RANDOM % 100))" "$((RANDOM % 100))"
}

# Pick N distinct random tags from a fixed pool.
rand_tags() {
  local count="${1:-2}"
  local pool=(deploy smoke build setup maintenance docker runner backup)
  local picked=()
  local i pick
  for ((i = 0; i < count; i++)); do
    pick="${pool[$((RANDOM % ${#pool[@]}))]}"
    # avoid duplicates
    [[ " ${picked[*]} " == *" ${pick} "* ]] || picked+=("${pick}")
  done
  printf '%s\n' "${picked[@]}"
}

# Default iteration count for property tests. Tests can override via $ITERATIONS.
PROPERTY_ITERATIONS="${PROPERTY_ITERATIONS:-25}"
export PROPERTY_ITERATIONS

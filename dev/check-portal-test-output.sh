#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root/portal"
export MIX_ENV=test

output="$(mktemp)"
clean_output="$(mktemp)"
trap 'rm -f "$output" "$clean_output"' EXIT

pollution_pattern='(^|[[:space:]])warning:|\[(error|warning)\]|(^|[[:space:]])error:|Postgrex\.Protocol .*disconnected|DBConnection\.ConnectionError'

strip_ansi() {
  sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g' "$1" >"$2"
}

run_and_check() {
  local label="$1"
  shift

  printf '==> %s\n' "$label"

  if ! "$@" >"$output" 2>&1; then
    cat "$output"
    printf '\nFAIL: %s failed\n' "$label" >&2
    return 1
  fi

  strip_ansi "$output" "$clean_output"

  if grep -nE "$pollution_pattern" "$clean_output" >&2; then
    cat "$output"
    printf '\nFAIL: %s polluted test output; fix the warning/error/log source.\n' "$label" >&2
    return 1
  fi

  cat "$output"
}

# Warm third-party deps UNSCANNED first: on a cold build (fresh clone, or a coop
# box with its own MIX_BUILD_ROOT) the first scanned step would compile the whole
# dep tree, and upstream packages' own compile warnings (e.g. sentry's
# `unused require Logger`) would trip the guard on noise that isn't ours to fix.
# Emisar's own apps still compile inside the scanned steps below, so a warning in
# OUR code is still caught. On a warm tree this is a fast no-op.
printf '==> deps warm-up (unscanned: third-party compile warnings are not ours)\n'
if ! bash -lc 'mix deps.compile' >"$output" 2>&1; then
  cat "$output"
  printf '\nFAIL: deps compile failed\n' >&2
  exit 1
fi

run_and_check "database setup and migrations" bash -lc \
  'cd apps/emisar && mix ecto.create --quiet && mix ecto.migrate --quiet'

run_and_check "emisar app tests" bash -lc 'cd apps/emisar && mix test'
run_and_check "emisar_web app tests" bash -lc 'cd apps/emisar_web && mix test'

printf '\nok: portal test output is clean\n'

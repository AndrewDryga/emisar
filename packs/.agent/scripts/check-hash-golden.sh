#!/usr/bin/env bash
# Cross-impl hash-golden guard for the redis + cassandra packs.
#
# The portal test apps/emisar_web/test/emisar_web/packs_test.exs pins the
# content_hash of redis (exec-only) and cassandra (has a script-kind action)
# byte-for-byte — the proof that the Elixir PacksRegistry and the Go runner hash
# a pack identically. `emisar pack validate` does NOT run that test, so ANY byte
# change to those two packs (including a catalog-wide sweep that only touches
# their action text) leaves the golden stale and the PORTAL build RED — silently,
# from the packs side (packs/AGENTS.md). This recomputes both hashes with the same
# loader `emisar pack validate` uses and compares them to the golden literals, so
# the drift is caught here at the packs gate / commit instead of in a later
# portal build.
#
#   check-hash-golden.sh          verify — exit 0 match, 1 stale (prints the fix), 2 can't-run
#   check-hash-golden.sh --write  rewrite the two golden literals to the current hashes
#
# Runs from anywhere in the repo. Fails open (exit 2) when no runnable emisar is
# found, so it can never wedge a commit on a missing tool — build bin/emisar from
# runner/ (go build -o ../bin/emisar .) to arm it.
set -euo pipefail

mode="${1:-check}"

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || {
  echo "check-hash-golden: not inside a git repo" >&2
  exit 2
}
cd "$root"

test_file="portal/apps/emisar_web/test/emisar_web/packs_test.exs"
[[ -f "$test_file" ]] || {
  echo "check-hash-golden: $test_file not found" >&2
  exit 2
}

# Locate a runnable emisar carrying the `pack validate` subcommand.
emisar="${EMISAR_BIN:-}"
if [[ -z "$emisar" ]]; then
  if [[ -x bin/emisar ]]; then
    emisar="bin/emisar"
  elif command -v emisar >/dev/null 2>&1; then
    emisar="emisar"
  fi
fi
if [[ -z "$emisar" ]] || ! "$emisar" pack validate packs/redis >/dev/null 2>&1; then
  echo "check-hash-golden: no runnable 'emisar pack validate' — build bin/emisar from runner/ (go build -o ../bin/emisar .); skipping" >&2
  exit 2
fi

compute() { "$emisar" pack validate "packs/$1" 2>/dev/null | sed -n 's/^hash: //p'; }

# Read the golden literal that follows each pack's `.content_hash ==` marker
# (the ` ==` excludes the non-golden `redis["hash"] == …get("redis").content_hash`
# comparison elsewhere in the file).
golden() { grep -A1 -E "get\\(\"$1\"\\)\\.content_hash ==" "$test_file" | grep -oE 'sha256:[0-9a-f]{64}' | head -1; }

redis_now=$(compute redis)
cassandra_now=$(compute cassandra)

if [[ "$mode" == "--write" ]]; then
  RH="$redis_now" CH="$cassandra_now" perl -i -pe '
    $want = "r" if /get\("redis"\)\.content_hash ==/;
    $want = "c" if /get\("cassandra"\)\.content_hash ==/;
    if ($want && s/sha256:[0-9a-f]{64}/$want eq "r" ? $ENV{RH} : $ENV{CH}/e) { $want = "" }
  ' "$test_file"
  echo "check-hash-golden: refreshed goldens in $test_file (redis=$redis_now cassandra=$cassandra_now)"
  echo "  Now run: (cd portal/apps/emisar_web && mix test test/emisar_web/packs_test.exs)"
  exit 0
fi

redis_gold=$(golden redis)
cassandra_gold=$(golden cassandra)

if [[ "$redis_now" == "$redis_gold" && "$cassandra_now" == "$cassandra_gold" ]]; then
  exit 0
fi

{
  echo "cross-impl hash golden is STALE in $test_file:"
  [[ "$redis_now" != "$redis_gold" ]] && echo "  redis:     golden $redis_gold != actual $redis_now"
  [[ "$cassandra_now" != "$cassandra_gold" ]] && echo "  cassandra: golden $cassandra_gold != actual $cassandra_now"
  echo
  echo "A redis/ or cassandra/ byte change moved the pack hash but the golden in"
  echo "packs_test.exs was not refreshed — the portal build will go RED. Fix it:"
  echo "  bash packs/.agent/scripts/check-hash-golden.sh --write"
  echo "  (cd portal/apps/emisar_web && mix test test/emisar_web/packs_test.exs)"
} >&2
exit 1

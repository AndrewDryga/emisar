#!/usr/bin/env bash
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
selector="$repo/.github/scripts/select-ci.sh"
frozen="$repo/.github/scripts/check-frozen-migrations.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q
git -C "$tmp" config user.name test
git -C "$tmp" config user.email test@example.com
mkdir -p "$tmp/portal/apps/emisar/priv/repo/migrations" "$tmp/runner"
printf 'defmodule Old do\nend\n' >"$tmp/portal/apps/emisar/priv/repo/migrations/20260101000000_old.exs"
printf 'package main\n' >"$tmp/runner/old.go"
git -C "$tmp" add .
git -C "$tmp" commit -qm base
base=$(git -C "$tmp" rev-parse HEAD)

assert_output() {
  local expected=$1 output=$2
  grep -Fxq "$expected" "$output" || {
    echo "missing selector output '$expected'" >&2
    cat "$output" >&2
    exit 1
  }
}

# A rename out of portal is a deletion plus an addition. Portal validation must
# still run for the deleted source path.
mkdir -p "$tmp/docs"
git -C "$tmp" mv portal/apps/emisar/priv/repo/migrations/20260101000000_old.exs docs/old.exs
git -C "$tmp" commit -qm rename
out="$tmp/rename.out"
(cd "$tmp" && GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null "$selector" push "$base")
assert_output portal=true "$out"
if (cd "$tmp" && "$frozen" push "$base" >"$tmp/rename-frozen.log" 2>&1); then
  echo "renaming a committed migration must fail" >&2
  exit 1
fi
git -C "$tmp" reset --hard -q "$base"

# Git may quote newline-bearing paths in human output. NUL parsing must keep the
# path intact and select the runner gate.
printf 'package main\n' >"$tmp/runner/line
break.go"
git -C "$tmp" add .
git -C "$tmp" commit -qm newline
out="$tmp/newline.out"
(cd "$tmp" && GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null "$selector" push "$base")
assert_output 'go_modules=["runner"]' "$out"
git -C "$tmp" reset --hard -q "$base"

# New migrations are allowed; modifying or deleting the committed migration is not.
printf 'defmodule New do\nend\n' >"$tmp/portal/apps/emisar/priv/repo/migrations/20260102000000_new.exs"
git -C "$tmp" add .
git -C "$tmp" commit -qm add-migration
(cd "$tmp" && "$frozen" push "$base")
git -C "$tmp" reset --hard -q "$base"
rm "$tmp/portal/apps/emisar/priv/repo/migrations/20260101000000_old.exs"
git -C "$tmp" add -u
git -C "$tmp" commit -qm delete-migration
if (cd "$tmp" && "$frozen" push "$base" >"$tmp/delete-frozen.log" 2>&1); then
  echo "deleting a committed migration must fail" >&2
  exit 1
fi

echo "ok: CI selector and frozen-migration adversarial cases pass"

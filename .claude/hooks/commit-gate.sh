#!/usr/bin/env bash
# Claude's native PreToolUse adapter. Shared staged-tree policy lives in the Go
# devtool so CI, humans, and other agents can run the same implementation.
set -u

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || exit 0
printf '%s' "$cmd" | grep -qE '\bgit\b.+\bcommit\b' || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -n "$root" && -x "$root/dev/run" ]] || exit 0

if ! output=$("$root/dev/run" check staged 2>&1); then
  printf '%s\n' "$output" >&2
  exit 2
fi

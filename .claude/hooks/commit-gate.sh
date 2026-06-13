#!/usr/bin/env bash
# PreToolUse(Bash) commit gate — refuse to commit unformatted Go.
#
# Fires only on `git commit`. Runs `gofmt -l -s` on the STAGED .go files (scoped,
# so an unrelated unformatted file elsewhere in the tree never blocks your commit).
# Block = exit 2 with the offending files on stderr.
#
# Go only, format only — on purpose. gofmt is fast and part of the toolchain.
# Portal Elixir format/compile/credo/test is the agent's per-task gate (the
# Definition of Done) plus CI; it is deliberately NOT re-run here — a whole-project
# Elixir check on every commit is slow and would false-block a commit on unrelated
# in-flight breakage. Fails OPEN on any infra problem so it can never wedge commits.

command -v jq >/dev/null 2>&1 || exit 0
command -v gofmt >/dev/null 2>&1 || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
printf '%s' "$cmd" | grep -qE '\bgit\b.+\bcommit\b' || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -z "$root" ]] && exit 0
cd "$root" || exit 0

go_files=()
while IFS= read -r f; do
  [[ "$f" == *.go && -f "$f" ]] && go_files+=("$f")
done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
[[ ${#go_files[@]} -eq 0 ]] && exit 0

unformatted=$(gofmt -l -s "${go_files[@]}" 2>/dev/null)
[[ -z "$unformatted" ]] && exit 0

{
  echo "commit blocked — staged Go files are not gofmt-clean:"
  printf '%s\n' "$unformatted" | sed 's/^/  /'
  echo "Fix: gofmt -w -s <files>, then re-stage and commit."
} >&2
exit 2

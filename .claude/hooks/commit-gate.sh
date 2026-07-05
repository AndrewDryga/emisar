#!/usr/bin/env bash
# PreToolUse(Bash) commit gate. Fires only on `git commit`; inspects the STAGED
# tree; blocks (exit 2, reason on stderr) on a violation. Fails OPEN on any infra
# problem so it can never wedge commits. Three scoped, fast checks:
#
#   1. Frozen migrations — refuse a commit that MODIFIES or DELETES a migration
#      already in git. The control plane is deployed (Fly `release_command` runs
#      each migration exactly once); a committed migration is permanent history,
#      so editing the file never re-applies and prod's schema silently drifts from
#      the code → outages. Add a NEW forward migration instead. (IL-11 / portal
#      AGENTS.md §8 / .agent/rules/migrations-frozen.md.)
#   2. Terraform format — refuse to commit `terraform fmt`-dirty staged .tf files
#      (infra/). Fails open if terraform isn't on PATH.
#   3. Go format — refuse to commit gofmt-dirty staged .go files.
#
# Portal Elixir format/compile/credo/test is the agent's per-task gate (Definition
# of Done) plus CI; a whole-project Elixir check on every commit is slow and would
# false-block a commit on unrelated in-flight breakage, so it is deliberately NOT
# re-run here. These two checks are git/gofmt only — fast and scoped to staged files.

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
printf '%s' "$cmd" | grep -qE '\bgit\b.+\bcommit\b' || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -z "$root" ]] && exit 0
cd "$root" || exit 0

# 1. Frozen migrations — a committed migration must never be edited or deleted.
#    M=modified, D=deleted, R=renamed against HEAD; a brand-new migration is A and
#    passes. Pathspec wildcards match any app's migrations dir.
frozen=$(git diff --cached --name-status --diff-filter=MDR -- '*priv/repo/migrations/*.exs' 2>/dev/null | cut -f2-)
if [[ -n "$frozen" ]]; then
  {
    echo "commit blocked — editing/deleting a migration that is already committed:"
    printf '%s\n' "$frozen" | sed 's/^/  /'
    echo
    echo "A committed migration has run in prod and never re-applies, so editing it"
    echo "diverges prod's schema from the code and takes prod down. Restore it"
    echo "(git checkout -- <file>) and add a NEW forward migration instead."
    echo "See portal AGENTS.md §8 + .agent/rules/migrations-frozen.md."
  } >&2
  exit 2
fi

# 2. Terraform format — staged .tf files (infra/) must be `terraform fmt`-clean.
# Fails open if terraform isn't on PATH; only exits on a violation, so a clean run
# falls through to the Go check below.
if command -v terraform >/dev/null 2>&1; then
  tf_files=$(git diff --cached --name-only --diff-filter=ACM -- '*.tf' 2>/dev/null)
  if [[ -n "$tf_files" ]]; then
    tf_dirs=$(printf '%s\n' "$tf_files" | while IFS= read -r f; do [[ -n "$f" ]] && dirname "$f"; done | sort -u)
    tf_bad=""
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      out=$(terraform fmt -check -no-color "$d" 2>/dev/null) || true
      [[ -n "$out" ]] && tf_bad+="$out"$'\n'
    done <<< "$tf_dirs"
    if [[ -n "${tf_bad//[$'\n ']/}" ]]; then
      {
        echo "commit blocked — staged Terraform is not 'terraform fmt'-clean:"
        printf '%s' "$tf_bad" | sed 's/^/  /'
        echo "Fix: terraform fmt <dir>, then re-stage and commit."
      } >&2
      exit 2
    fi
  fi
fi

# 3. Go format — staged .go files must be gofmt-clean.
command -v gofmt >/dev/null 2>&1 || exit 0

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

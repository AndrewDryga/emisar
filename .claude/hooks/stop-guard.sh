#!/usr/bin/env bash
# Stop hook — keep an autonomous batch running until the queue is clear.
#
# INERT BY DEFAULT so it never nags an interactive session. It enforces ONLY when
# a batch is explicitly active — the sentinel file .claude/.batch-active exists.
# During a batch it blocks Stop (exit 2) while any project's .agent/TASKS.md still
# has an open `- [ ]` item. `- [w]` (claimed/in-progress) and `- [B]` (blocked) do
# NOT count — a `- [w]` is a live claim held by some agent (it resolves to [x], or
# back to [ ] if abandoned); a `- [B]` is triaged to PENDING_DECISIONS.md.
#
# Escapes (any one clears the gate): finish the task, mark it `- [B]` and add a
# PENDING_DECISIONS.md entry, or end the batch with `rm .claude/.batch-active`.
# Honors stop_hook_active so it can never wedge a session in a tight loop.
#
#   Start an enforced batch:  touch .claude/.batch-active
#   End it:                   rm .claude/.batch-active
#
# This is the durable backstop; /goal and /loop are the primary "run to
# completion" drivers. Disable entirely: remove the Stop block from settings.json.

command -v jq >/dev/null 2>&1 || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -z "$root" ]] && exit 0
[[ -f "$root/.claude/.batch-active" ]] || exit 0   # inert unless a batch is active

input=$(cat)
[[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" == "true" ]] && exit 0

open=""
while IFS= read -r f; do
  if grep -qE '^[[:space:]]*- \[ \]' "$f" 2>/dev/null; then
    n=$(grep -cE '^[[:space:]]*- \[ \]' "$f")
    proj=$(basename "$(dirname "$(dirname "$f")")")
    open="${open}  - ${proj}: ${n} open in ${f#"$root"/}"$'\n'
  fi
done < <(find "$root" -maxdepth 4 -path '*/.agent/TASKS.md' 2>/dev/null)

[[ -z "$open" ]] && exit 0

cat >&2 <<MSG
Batch active, queue not clear — open tasks remain:
${open}
Continue: take the first open task, gate it green, commit, tick it [x]. If it is
blocked, mark it '- [B]' and add a PENDING_DECISIONS.md entry. To end the batch,
remove the sentinel: rm .claude/.batch-active
MSG
exit 2

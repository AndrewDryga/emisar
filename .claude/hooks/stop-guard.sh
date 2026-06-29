#!/usr/bin/env bash
# Stop hook — keep an autonomous sweep running until the queue is clear.
#
# INERT BY DEFAULT so it never nags an interactive session. It enforces ONLY when
# a sweep is explicitly active — the sentinel file .claude/.sweep-active exists.
# During a sweep it blocks Stop (exit 2) while any project's .agent/tasks/00_todo/
# still holds an unclaimed task. A claimed task (10_in_progress/) is some agent's
# live work — it resolves to done, or back to todo if abandoned — and a blocked
# task (50_blocked/) is parked on its decision.md, so neither counts as open work.
#
# Escapes (any one clears the gate): finish the task ('coop tasks done <id>'),
# block it ('coop tasks block <id>' + fill its decision.md), or end the sweep with
# 'rm .claude/.sweep-active'. Honors stop_hook_active so it can never wedge a session.
#
#   Start an enforced sweep:  touch .claude/.sweep-active
#   End it:                   rm .claude/.sweep-active
#
# This is the durable backstop; /goal and /loop are the primary "run to
# completion" drivers. Disable entirely: remove the Stop block from settings.json.

command -v jq >/dev/null 2>&1 || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -z "$root" ]] && exit 0
[[ -f "$root/.claude/.sweep-active" ]] || exit 0   # inert unless a sweep is active

input=$(cat)
[[ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false')" == "true" ]] && exit 0

open=""
while IFS= read -r d; do
  todo="$d/00_todo"
  [[ -d "$todo" ]] || continue
  n=$(find "$todo" -mindepth 2 -maxdepth 2 -name task.md 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${n:-0}" -gt 0 ]]; then
    proj=$(basename "$(dirname "$(dirname "$d")")")
    open="${open}  - ${proj}: ${n} unclaimed in ${d#"$root"/}/00_todo"$'\n'
  fi
done < <(find "$root" -maxdepth 4 -type d -path '*/.agent/tasks' 2>/dev/null)

[[ -z "$open" ]] && exit 0

cat >&2 <<MSG
Sweep active, queue not clear — unclaimed tasks remain:
${open}
Continue: claim the next task ('coop tasks claim <id>'), gate it green, commit, then
'coop tasks done <id>'. If it is blocked, 'coop tasks block <id>' and fill its
decision.md. To end the sweep, remove the sentinel: rm .claude/.sweep-active
MSG
exit 2

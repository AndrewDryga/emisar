#!/bin/bash
# Claude activates this hook only while /workflow-sweep is active (it's declared in the skill's
# frontmatter, scoped to the skill's lifetime — no repo-global sentinel). Queue state is
# authoritative on every Stop attempt: the model releases itself by finishing or blocking each
# actionable task. Aggregates every project's .agent/tasks queue (the monorepo has one per member).

queue_paths() {
  if command -v coop >/dev/null 2>&1; then
    paths=$(cd "$CLAUDE_PROJECT_DIR" && coop tasks queues) || return 1
    printf '%s\n' "$paths"
    return
  fi
  find "$CLAUDE_PROJECT_DIR" -type d -path '*/.agent/tasks' -prune -print
}

paths=$(queue_paths) || {
  echo "Sweep queue guard could not discover task queues; refusing to stop. Fix the reported error and retry." >&2
  exit 2
}
left=0
while IFS= read -r q; do
  [ -n "$q" ] || continue
  if [ -L "$q" ]; then
    echo "Sweep queue guard refuses symlinked queue root: $q" >&2
    exit 2
  fi
  if [ ! -d "$q" ]; then
    echo "Sweep queue guard cannot read configured queue root: $q" >&2
    exit 2
  fi
  # Count 00_todo ONLY: a 10_in_progress/ task is some agent's live CLAIM (this repo runs
  # Claude + Codex in one tree — AGENTS.md don't-stop contract), so it must not block a
  # different agent's Stop. Unclaimed todo work is the unambiguous "keep going" signal.
  state="00_todo"
  [ -d "$q/$state" ] || continue
  tasks=$(find "$q/$state" -mindepth 1 -maxdepth 1 -type d -print) || {
    echo "Sweep queue guard cannot count $q/$state; refusing to stop." >&2
    exit 2
  }
  n=0
  while IFS= read -r task; do
    [ -n "$task" ] && n=$((n + 1))
  done <<< "$tasks"
  left=$((left + ${n:-0}))
done <<< "$paths"
if [ "${left:-0}" -gt 0 ]; then
  echo "$left unclaimed task(s) remain in 00_todo across the repo's queues. Keep sweeping: claim + finish, or block, every task before stopping." >&2
  exit 2
fi

#!/usr/bin/env bash
# PostToolUse hook — Iron Law + house-rule verification after Edit/Write.
#
# All rules live in ONE place: portal/.credo.exs + the custom AST checks in
# portal/credo/checks/ (Emisar.Checks.*). This hook just runs `mix credo` on
# the touched file and, on any finding, writes the issues to stderr and exits
# 2 — which the harness treats as a blocking error and feeds back so the
# violation is fixed on the spot instead of in review. ~0.6s per edit.
#
# Scope: ONLY portal/ Elixir files (.ex/.exs). Go/MCP/runner edits and .heex
# (credo doesn't parse templates) exit 0 immediately. The judgment-dependent
# laws a static check can't decide (IL-3/4/5 authz shape, IL-10 internal
# preloads, IL-15 event authz, IL-16 raw/1 on attacker text) stay in
# /iron-review, which can read bodies and trace where a value came from.
#
# Disable: delete the PostToolUse block from .claude/settings.json.

# jq is required to parse the hook payload; degrade to no-op if absent.
command -v jq >/dev/null 2>&1 || exit 0

FILE_PATH=$(cat | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# Portal Elixir files only (credo can't parse .heex).
[[ "$FILE_PATH" == */portal/* ]] || exit 0
case "$FILE_PATH" in
  *.ex|*.exs) ;;
  *) exit 0 ;;
esac
[[ -f "$FILE_PATH" ]] || exit 0

PORTAL_DIR="${FILE_PATH%%/portal/*}/portal"
[[ -f "$PORTAL_DIR/.credo.exs" ]] || exit 0

# mix lives behind the asdf shims (homebrew elixir shadows the repo version).
export PATH="$HOME/.config/asdf/shims:$PATH"
command -v mix >/dev/null 2>&1 || exit 0

OUTPUT=$(cd "$PORTAL_DIR" && mix credo "$FILE_PATH" --format oneline 2>/dev/null)
STATUS=$?

if [[ $STATUS -ne 0 && -n "$OUTPUT" ]]; then
  cat >&2 <<MSG
CREDO VIOLATION(S) in $(basename "$FILE_PATH") — Iron Laws / house rules:
$OUTPUT

These are non-negotiable (portal/CLAUDE.md; custom checks in portal/credo/checks/).
Fix before proceeding, then re-check with: mix credo $FILE_PATH
MSG
  exit 2
fi
exit 0

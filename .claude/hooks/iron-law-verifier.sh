#!/usr/bin/env bash
# PostToolUse hook — programmatic Iron Law verification after Edit/Write.
#
# Scans the CODE CONTENT of the just-written file and, on a violation, writes
# the specific law to stderr and exits 2 — which the harness treats as a
# blocking error and feeds back so the violation is fixed on the spot instead
# of in review. Read-only, ~10ms.
#
# Scope: ONLY portal/ Elixir files (.ex/.exs/.heex). Go/MCP/runner edits exit 0
# immediately. Laws + rationale live in portal/CLAUDE.md.
#
# This hook only enforces the HIGH-PRECISION, zero-false-positive subset of the
# Iron Laws (IL-1, IL-2, IL-6, IL-7, IL-8, IL-12). The judgment-heavy laws are
# checked by `/iron-review`, which can read function bodies and trace where a
# value came from: IL-3/4/5 authz shape, IL-13 Oban args, IL-14 String.to_atom
# (safe on code literals, unsafe on request/runner input), IL-15 event authz,
# IL-16 raw/1 (safe on app-generated SVG/markdown, unsafe on attacker text),
# IL-17/18 OTP/LiveView, IL-20 verify. A hook check must hold for EVERY
# occurrence — if a value's safety depends on its SOURCE, it belongs in the
# skill, not here, or it will block legitimate edits.
#
# Disable: delete the PostToolUse block from .claude/settings.json.

# jq is required to parse the hook payload; degrade to no-op if absent.
command -v jq >/dev/null 2>&1 || exit 0

FILE_PATH=$(cat | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# Portal Elixir files only.
[[ "$FILE_PATH" == */portal/* ]] || exit 0
case "$FILE_PATH" in
  *.ex|*.exs|*.heex) ;;
  *) exit 0 ;;
esac
[[ -f "$FILE_PATH" ]] || exit 0

# --- path predicates -------------------------------------------------------
in_lib_emisar=0;  [[ "$FILE_PATH" == */portal/apps/emisar/lib/emisar/* ]] && in_lib_emisar=1
is_query=0;       [[ "$FILE_PATH" == */query.ex ]] && is_query=1
is_changeset=0;   [[ "$FILE_PATH" == */changeset.ex ]] && is_changeset=1
is_repo=0;        [[ "$FILE_PATH" == */repo.ex || "$FILE_PATH" == */repo/* ]] && is_repo=1
is_test=0;        [[ "$FILE_PATH" == *_test.exs || "$FILE_PATH" == */test/* ]] && is_test=1
is_schema=0;      grep -qE '^\s*use Emisar, :schema' "$FILE_PATH" 2>/dev/null && is_schema=1

VIOLATIONS=""
add() { VIOLATIONS="${VIOLATIONS}\n- Iron Law ${1} (line ${2}): ${3}"; }

# Return "LINE:content" of the first non-comment match, else empty.
hit() {
  grep -nE "$1" "$FILE_PATH" 2>/dev/null | while IFS= read -r line; do
    content="${line#*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"   # left-trim
    [[ "$trimmed" == \#* ]] && continue                 # skip Elixir comments
    echo "$line"; break
  done
}
lineno() { echo "${1%%:*}"; }

# --- IL-2: never Repo.get / get! / get_by (bypasses Query module) ----------
if [[ $in_lib_emisar == 1 && $is_test == 0 ]]; then
  m=$(hit '\bRepo\.(get|get!|get_by)\(')
  [[ -n "$m" ]] && add "#2" "$(lineno "$m")" "Repo.get/get!/get_by bypasses the Query module — build via Schema.Query and use Repo.fetch/3."
fi

# --- IL-1: no import Ecto.Query in a context / worker ----------------------
if [[ $in_lib_emisar == 1 && $is_query == 0 && $is_repo == 0 ]]; then
  m=$(hit '^\s*import Ecto\.Query')
  [[ -n "$m" ]] && add "#1" "$(lineno "$m")" "import Ecto.Query in a context/worker — move the query into the Schema.Query module (use \`use Emisar, :query\` there)."
fi

# --- IL-6: Query modules never call Repo (excludes the repo/ machinery) ----
if [[ $is_query == 1 && $is_repo == 0 ]]; then
  m=$(hit '\bRepo\.[a-z]')   # Repo.<fn> calls only — not Repo.Query/Repo.Filter module refs
  [[ -n "$m" ]] && add "#6" "$(lineno "$m")" "Repo.* call inside a Query module — Query modules only build queryables; the context calls Repo."
fi

# --- IL-8: Changeset modules are pure (no Repo; excludes the repo/ machinery) --
if [[ $is_changeset == 1 && $is_repo == 0 ]]; then
  m=$(hit '\bRepo\.[a-z]')   # Repo.<fn> calls only — not Repo.Query/Repo.Filter module refs
  [[ -n "$m" ]] && add "#8" "$(lineno "$m")" "Repo.* call inside a Changeset module — changesets are pure; do DB work in the context."
fi

# --- IL-7: Schema modules carry no changeset logic -------------------------
if [[ $is_schema == 1 ]]; then
  m=$(hit '(\|>\s*cast\(|^\s*def (changeset|create|update)\()')
  [[ -n "$m" ]] && add "#7" "$(lineno "$m")" "changeset logic in a Schema module — move cast/validate/create/update into Schema.Changeset; schemas are fields + associations only."
fi

# --- IL-12: no :float for money (schema fields + migrations) ---------------
m=$(hit '(field|add)[[:space:]]+:(price|amount|cost|total|subtotal|balance|fee|rate|charge|payment|salary|wage|budget|revenue|discount|tax|cents|money)[a-z_]*,[[:space:]]*:float')
[[ -n "$m" ]] && add "#12" "$(lineno "$m")" ":float for a money field — use :decimal or :integer (cents)."

# --- House: no pipe in a with/case/for head (one-line OR wrapped form) ------
# `{:ok, x} <- a() |> b()` hides the matched operation — bind the pipeline
# to a name above the head, then match the short call. Lib code only.
if [[ $is_test == 0 ]]; then
  m=$(hit '<-.*\|>')
  [[ -n "$m" ]] && add "house/with-head-pipe" "$(lineno "$m")" "pipe in a with/case/for head — bind \`queryable = …\` (or similar) above, then match \`<- Repo.peek(queryable)\`."

  # Wrapped form: the head ends in `<-` and the pipeline starts on the next line.
  m=$(awk 'prev ~ /<-[[:space:]]*$/ && /\|>/ {print NR; exit} {prev=$0}' "$FILE_PATH")
  [[ -n "$m" ]] && add "house/with-head-pipe" "$m" "wrapped pipe under a \`<-\` head — bind the pipeline to a name above the with/case, then match the name."
fi

# --- House: contexts never pass :preload opts — chain with_preloaded_* ------
if [[ $in_lib_emisar == 1 && $is_query == 0 && $is_repo == 0 && $is_test == 0 ]]; then
  m=$(hit ':preload\b')
  [[ -n "$m" ]] && add "house/preload-opt" "$(lineno "$m")" ":preload opt at a context call site — chain Schema.Query.with_preloaded_<assoc>() in the pipeline (before for_subject) instead."
fi

# --- House: LiveTable filter callbacks bind `queryable`, never `q` ----------
if [[ $is_test == 0 ]]; then
  m=$(hit '\bfn q\b')
  [[ -n "$m" ]] && add "house/fn-q" "$(lineno "$m")" "\`fn q\` — spell the binding out: \`fn queryable, …\` (DSL bindings like [runs: r] inside dynamic/where stay fine)."
fi

# IL-14 (String.to_atom) and IL-16 (raw/1) intentionally live in /iron-review,
# not here: their safety depends on whether the value is a code literal /
# app-generated (safe) or request/runner/LLM input (unsafe) — a judgment a
# regex can't make without false-positiving on legitimate code in this repo
# (e.g. raw(@mfa_qr_svg), String.to_atom on a bounded schema-table name).

if [[ -n "$VIOLATIONS" ]]; then
  cat >&2 <<MSG
IRON LAW VIOLATION(S) in $(basename "$FILE_PATH"):
$(echo -e "$VIOLATIONS")

These are non-negotiable (portal/CLAUDE.md → Iron Laws). Fix before proceeding.
MSG
  exit 2
fi
exit 0

#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$root"

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

ok() {
  printf 'ok: %s\n' "$*"
}

expect_link() {
  local path="$1"
  local target="$2"

  if [[ ! -L "$path" ]]; then
    fail "$path is not a symlink"
    return
  fi

  local actual
  actual="$(readlink "$path")"
  if [[ "$actual" != "$target" ]]; then
    fail "$path points to $actual, expected $target"
    return
  fi

  ok "$path -> $target"
}

extract_frontmatter_value() {
  local file="$1"
  local key="$2"

  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && index($0, key ":") == 1 {
      value = substr($0, length(key) + 2)
      sub(/^[[:space:]]+/, "", value)
      sub(/^"/, "", value)
      sub(/"$/, "", value)
      print value
      exit
    }
  ' "$file"
}

check_manual_text() {
  local findings
  findings="$(mktemp)"

  if rg -n 'coop tasks list|xx_done' AGENTS.md .claude/skills portal/AGENTS.md runner/AGENTS.md mcp/AGENTS.md packs/AGENTS.md infra/AGENTS.md >"$findings"; then
    cat "$findings" >&2
    fail "manuals or skills still mention stale coop task commands/state names"
  else
    ok "manuals and skills use current coop task commands/state names"
  fi
  rm -f "$findings"
}

check_skill_text() {
  local findings
  findings="$(rg -n -i '(/code-review|/security-review)|v0\.2|never shells out|never-a-shell|argv arrays, never shell strings|(^|[[:space:]`(])/(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|make-interfaces-feel-better|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api|work)\b|`(boundaries|context-fn|creative-director|deploy|deps-audit|frontend|investigate|iron-review|new-context|perf|recurrent-jobs|release|seo-marketing|ship-review|spec|sweep|testing|ux-designer|verify-api)`' .claude/skills || true)"

  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    fail "skills still mention retired review commands or stale product/security wording"
  else
    ok "skills use current review commands and product/security wording"
  fi
}

check_coop() {
  local help
  help="$(coop tasks --help)"

  [[ "$help" == *'ls [--all]'* ]] || fail "coop help no longer advertises 'tasks ls'"
  [[ "$help" == *'99_done/'* ]] || fail "coop help no longer advertises 99_done/"

  if coop tasks ls --all >/dev/null; then
    ok "coop tasks ls --all works"
  else
    fail "coop tasks ls --all failed"
  fi
}

check_task_dirs() {
  local queue task state
  while IFS= read -r queue; do
    if [[ -d "$queue/xx_done" ]]; then
      fail "$queue has stale xx_done/"
    fi

    while IFS= read -r task; do
      state="$(basename "$(dirname "$(dirname "$task")")")"
      case "$state" in
        00_todo | 10_in_progress | 50_blocked | 99_done) ;;
        *) fail "$task lives under unknown state $state" ;;
      esac
    done < <(find "$queue" -mindepth 3 -maxdepth 3 -name task.md | sort)
  done < <(find . -maxdepth 4 -type d -path '*/.agent/tasks' | sort)

  ok "task queues use expected state names"
}

check_rule_names() {
  local file base

  while IFS= read -r file; do
    base="$(basename "$file")"
    case "$base" in
      design-*.md | content-*.md | elixir-*.md | runner-*.md | mcp-*.md | packs-*.md | infra-*.md | shared-*.md) ;;
      *) fail "$file must use a domain prefix (design-, content-, elixir-, runner-, mcp-, packs-, infra-, or shared-)" ;;
    esac
  done < <(find . -type f -path '*/.agent/rules/*.md' | sort)

  ok "rule filenames use domain prefixes"
}

check_skills() {
  local file dir expected name description effort allowed_tools

  while IFS= read -r file; do
    dir="$(basename "$(dirname "$file")")"
    expected="$dir"
    name="$(extract_frontmatter_value "$file" name)"
    description="$(extract_frontmatter_value "$file" description)"
    effort="$(extract_frontmatter_value "$file" effort)"
    allowed_tools="$(extract_frontmatter_value "$file" allowed-tools)"

    [[ -n "$name" ]] || fail "$file missing frontmatter name"
    [[ -n "$description" ]] || fail "$file missing frontmatter description"
    [[ -n "$effort" ]] || fail "$file missing frontmatter effort"
    [[ -n "$allowed_tools" ]] || fail "$file missing frontmatter allowed-tools"
    case "$effort" in
      low | medium | high | max) ;;
      *) fail "$file effort '$effort' must be low, medium, high, or max" ;;
    esac
    [[ "$name" == "$expected" ]] || fail "$file name is '$name', expected '$expected'"
    case "$name" in
      content-* | debug-* | design-* | elixir-* | go-* | ops-* | product-* | review-* | security-* | tooling-* | workflow-*) ;;
      *) fail "$file name '$name' must use a recognized domain prefix" ;;
    esac
  done < <(find .claude/skills -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

  ok "skill frontmatter has matching name/description/effort/allowed-tools and domain prefixes"
}

for project in . infra mcp packs portal runner; do
  expect_link "$project/CLAUDE.md" AGENTS.md
done

expect_link .codex/skills ../.claude/skills

check_manual_text
check_skill_text
check_coop
check_task_dirs
check_rule_names
check_skills

if [[ "$failures" -gt 0 ]]; then
  printf '\nLLM setup audit failed: %d issue(s)\n' "$failures" >&2
  exit 1
fi

printf '\nLLM setup audit passed\n'

---
name: review-ship
description: Review a portal/ diff before merge through the product hats AND the Iron Laws in parallel — PM, UX, frontend, security, SEO/design (as relevant) plus elixir-iron-review, synthesized into one verdict. Use before opening a PR or when the user asks for a product/multi-hat/pre-ship review. Complements /elixir-iron-review (laws) and /review-board (the heavyweight whole-PR panel).
effort: high
argument-hint: "[git ref, default = working tree vs main]"
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# Ship review (the hats + the laws)

A pre-merge review that asks more than "is it correct?" — also "is it the right
thing, is it clear, is it safe, will it last?" Run it on the diff, fan out the
relevant lenses in parallel, synthesize one verdict.

## 1. Scope the diff and pick lenses

```sh
cd portal && git diff --stat main...HEAD   # or the given ref / working tree
```
Read the diff. Choose ONLY the hats the change actually touches — don't run SEO on
a pure context change. Mapping:

| The diff touches… | Run |
|---|---|
| any `lib/emisar/**` (context/query/changeset/authorizer) | **elixir-iron-review** (always) + **security-engineer** if auth/runner/MCP/policy/untrusted input |
| `lib/emisar_web/live/**`, `components/**`, `.heex` | **design-ux** + **design-frontend** |
| `controllers/marketing_html/**`, docs, copy, meta | **content-seo** + **design-review** |
| new user-facing capability, scope, or flow | **product-manager** |
| logic / correctness risk | suggest `/review-board` when the risk spans multiple surfaces; this skill is product-level, not a line-by-line bug hunt |

## 2. Fan out (parallel subagents)

Spawn one `Agent` per chosen lens, in a single batch so they run concurrently.
Give each the exact diff scope and tell it to load its hat:

> Read `.claude/skills/<hat>/SKILL.md` and review the diff `<ref>` **only** through
> that hat's checklist. Report findings as `severity · file:line · issue · fix`.
> Be specific to this diff; skip what's clean. ≤250 words. Do not edit code.

Always include the **elixir-iron-review** lens (`Read .claude/skills/elixir-iron-review/SKILL.md`,
run Steps 1–2 on the diff). For a heavy security surface, give the security agent
`omitClaudeMd`-style focus: abuse cases first.

## 3. Synthesize (you, in the main thread)

Collect all findings and produce ONE verdict — don't just concatenate:
- **De-dupe** overlaps (UX and frontend often flag the same thing — merge).
- **Rank** BLOCKER → SUGGESTION. A BLOCKER is: an Iron-Law violation, a security
  hole, data loss/leak, or "this ships the wrong thing". Everything else is a
  suggestion.
- **Resolve conflicts** between hats explicitly (e.g. PM wants it shipped thin,
  security wants a check — state the call and why).

```
## Ship review: <title>   —   <N blockers, M suggestions>
Verdict: SHIP / SHIP AFTER BLOCKERS / RETHINK

### Blockers
- [IL-4 | security] lib/…:42 — … → fix: …

### Suggestions
- [ux] …

### Hat notes
- PM: <one line> · UX: <…> · Security: <…>
```

Keep it honest and short. If it's clean, say "SHIP — nothing blocking" and list at
most the few suggestions worth the reader's time. Don't manufacture findings to look
thorough; don't bury a real blocker in noise.

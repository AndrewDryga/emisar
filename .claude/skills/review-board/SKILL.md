---
name: review-board
description: The full pre-merge review — convene a board of expert hats (pragmatic staff engineer, domain expert, security, UX, UI, PM, marketing, sales) as parallel review subagents, then synthesize ONE ranked verdict and a prioritized plan to fix everything. Supersedes running /security-review + /code-review + /ship-review separately — it's all of them, more hats, plus a fix plan you can hand to /sweep. Works on a PR, a branch/ref, a commit or range, or your uncommitted local changes — use before landing anything, or whenever you want a thorough multi-perspective review.
effort: max
argument-hint: "[nothing = local changes · commit hash · a..b range · branch/ref · PR number · -- pathspec]"
allowed-tools: Read, Grep, Glob, Bash, Agent
---

# /review-board — the panel reviews the change, you synthesize a fix plan

Convene a board of expert hats; each reviews the change through ONE lens **in parallel**;
then YOU (the parent) synthesize one ranked verdict and an ordered plan to fix everything.
This is the heavyweight, on-demand review — point it at a PR, a branch, a commit/range, or your
uncommitted local changes. It subsumes `/security-review`, `/code-review`,
and `/ship-review`'s product hats into one panel, across **all** areas (portal/runner/mcp/packs).
**Read-only: the board reviews; it never edits.** The deliverable is a *fix plan*, not just notes.

## 1. Scope the change — PR, branch, commit, range, or local edits
Resolve `$1` into a concrete diff + file list, then read it yourself first. Inputs:
- **nothing (default)** → your **uncommitted local changes**: `git diff HEAD` (staged + unstaged) plus untracked files from `git status --porcelain`. The "review what I'm working on right now" case.
- **a commit hash** (`a1b2c3d`) → that commit alone: `git show <hash>` / `git diff <hash>^..<hash>`.
- **a range** (`a..b`, `a...b`, `HEAD~3..HEAD`) → `git diff <range>`.
- **a branch / ref** (`feat-x`, a tag) → its diff vs the base: `git diff main...<ref>`.
- **a PR number** (`123` / `#123`) → `gh pr view <n> --json title,body,files` + `gh pr diff <n>` (read the title/body for **intent**).
- **a pathspec / file(s)** (`-- runner/…`) → narrows ANY of the above to those paths.

**Mind a shared working tree.** With a concurrent agent (Codex) editing, "local changes" can include work that isn't yours — `git diff HEAD` shows everyone's. Narrow with a pathspec, or review a specific commit/range/PR instead, when you want only your slice.

For **intent** on a non-PR scope, read the commit message(s) in range, or — for uncommitted work — the `.agent/TASKS.md` / `LOG.md` context; if what the change is *for* is unclear, say so (a reviewer who doesn't know the goal judges the wrong things).

**Announce the resolved scope before convening the board** — the input mode + the exact file list. Note which areas it touches — portal/ (Elixir), runner/ or mcp/ (Go), packs/ (YAML), marketing, billing/pricing, docs — which drives the hats.

## 2. Convene the board (the hats the change earns)
**Standing hats — always, for any code change:**
- **Pragmatic staff engineer** — correctness & edge cases, the simplest thing that works, over-engineering, maintainability, "would I approve this PR?" (the `/code-review` lens + the creed).
- **Domain expert** — does it fit emisar's architecture + trust model? Load the touched project's `AGENTS.md`: portal → the Iron Laws (`/iron-review`); runner/mcp → the security posture; packs → the conventions. emisar is an AI-safe infra control plane — flag anything that bends the model.
- **Security engineer** — lead with the abuse case. **Mandatory — emisar IS a security product** (`/security-engineer`).

**Earned hats — add when the diff touches their surface (lean toward MORE coverage; this is the thorough review):**

| The diff touches… | Add |
|---|---|
| LiveView / HEEx / components (operator-facing) | **UX designer** (`/ux-designer`) + **UI/frontend** (`/frontend`) |
| a new capability, scope, or user flow | **PM** (`/product-manager` — right thing? smallest slice?) |
| marketing site / positioning / docs that rank | **marketing/SEO** (`/seo-marketing`) |
| pricing, plans, plan-gating, billing, or a sellable/demoable capability | **sales** (no skill — lens: does it answer a buyer objection? is it demoable? is the plan-gating right? does it help close/expand a deal?) |

## 3. Fan out — one Agent per hat, in a single parallel batch
Spawn them concurrently (one message, many `Agent` calls). Give each the ref + touched files and this brief:

> You are the **<hat>** reviewing change `<ref>`. Read `.claude/skills/<skill>/SKILL.md` (if one maps
> to your hat) and the touched files **in full** — plus their callers/tests for context, not just the
> diff hunks. Review **only** through the <hat> lens. Report findings as a list, each:
> `SEVERITY · file:line · issue · why it matters · concrete fix`. SEVERITY ∈ BLOCKER / MAJOR / MINOR / NIT.
> Be specific to THIS change; skip what's clean; don't invent findings to look thorough. ≤300 words.
> **Do NOT edit code — review only.**

Tell the security + domain hats to lead with the abuse case / the exact law each finding breaks.

## 4. Synthesize (you, the parent — don't just concatenate)
- **Dedupe** overlaps (UX+UI, staff+domain flag the same thing — merge, keep the sharpest wording).
- **Rank** BLOCKER → MAJOR → MINOR → NIT. BLOCKER = ships the wrong thing, a security hole, data loss/leak, an Iron-Law violation, or a real correctness bug.
- **Resolve cross-hat conflicts explicitly** — PM wants it thin, security wants a gate: state the call + why.
- One-line **verdict**: SHIP / SHIP-AFTER-BLOCKERS / RETHINK.

## 5. Write the fix plan (the deliverable)
Turn the ranked, deduped findings into an ordered, actionable plan — blockers first, then by area/risk:

```
## Review board: <title>   —   verdict: <…>   (<N blockers, M major, K minor>)

Headline: <2–3 sentences — ship-ability + the one thing that matters most>

### Findings (ranked, deduped)
- BLOCKER [security · staff] lib/…:42 — <issue> → fix: <…>
- MAJOR  [ux] …

### Fix plan (ordered; blockers/riskiest first)
1. <fix> — <what + where> — closes: [security:1, staff:3] — <independent | needs #N>
2. …

### Hat notes (one line each)
staff: … · domain: … · security: … · ux: … · pm: … · sales: …
```

Keep it honest and short. If it's clean: **"SHIP — nothing blocking"** + the few suggestions worth the reader's time. Never manufacture findings to look thorough, never bury a real blocker in nits.

**Then offer to queue it:** the BLOCKER/MAJOR items become `- [ ]` tasks in the touched project's `.agent/TASKS.md`, so `/sweep` can drain the fixes to a ship-ready bar. Append on the user's go — never silently.

## Relationship to the focused reviews
`/review-board` convenes them all; the single-lens tools are its building blocks and stay for fast, focused runs: `/iron-review` (laws), `/code-review` (bugs), `/security-engineer`, `/ux-designer`, etc. `/ship-review` is the lighter, proportional *in-loop* self-review `/sweep` runs per item; `/review-board` is the heavyweight on-demand whole-PR review that ends in a plan.

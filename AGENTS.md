# emisar — how we work (canonical agent manual)

`emisar` is a control plane for AI-safe infrastructure actions: operators — and LLMs via MCP — dispatch **gated, audited** actions to a fleet of on-host runners. **It is a security product.** Treat every surface that ingests runner / LLM / operator input as hostile until proven otherwise.

This file is the **canonical, tool-neutral operating manual** for any AI agent (Claude Code, Codex, …) working in this repo. `CLAUDE.md` is a symlink to it. Read it top to bottom — it is deliberately small; the deep, per-language rules live in each project's own `AGENTS.md`.

---

## ⟢ BOOT — read this when you start, or lose context

Context compaction drops everything except this file (re-injected from disk) and your tool's memory. When you start fresh, resume after a compaction, or feel unsure what you were doing, **re-read in this order before touching code**:

1. **This file** — the creed + the contract below.
2. **The project's `AGENTS.md`, in full** — not a skim. The rules are non-negotiable and you *will* violate them from memory.
3. **`<project>/.agent/LOG.md`** (if present) — your own recent chain-of-thought: what you were doing and *why*, and the next step you set yourself. This is how intent survives a compaction.
4. **`<project>/.agent/TASKS.md`** — the work queue. Resume at the first unchecked `[ ]`.

Four top-level areas, each with its own `AGENTS.md` + `.agent/`:

| Project | Language | What it is | Read before editing |
|---|---|---|---|
| `portal/` | Elixir / Phoenix | the control plane (web, MCP, policy, approvals, audit, billing) | `portal/AGENTS.md` |
| `runner/` | Go | the on-host runner that executes actions | `runner/AGENTS.md` |
| `mcp/` | Go | the stdio↔HTTP MCP bridge for LLM clients | `mcp/AGENTS.md` |
| `packs/` | YAML | the action-pack catalog — what runners may execute | `packs/AGENTS.md` |

---

## The creed — how we build (every project)

Generalize from these; defer to the project `AGENTS.md` for specifics.

1. **Pragmatic. Boring solutions that work.** Reach for the dull, proven shape first. Clever earns its place only when boring genuinely can't do the job — and you can say *why* in one sentence. No frameworks-within-the-framework, no speculative abstraction.
2. **We ship a good, _sellable_ product.** Every change serves a real operator need. Wear the hats before writing code — **PM** (is this the right thing to build, or should it be cut or smaller?), **UX** (is the operator's path obvious; are the empty / error / loading / offline states handled?), **Security** (what's the abuse case?), **Marketing** (does this make the product easier to explain and sell?), **Maintainer** (will this read clearly in six months?). Care about product, quality, UX, and marketing *genuinely* — but pragmatically: a half-built "platform" sells nothing; a small thing done well does.
3. **Readable code, no bloat.** Match the surrounding style exactly. Delete more than you add when you can. No config knobs nobody asked for, no "just in case" parameters, no comments narrating *what* — comments say *why*.
4. **Done means verified, not done-once.** A change is done when it compiles clean, is formatted, passes its gate, is covered by tests (including the denial / abuse path where it applies), and is obvious — not when it ran once. Never say "should work"; show the gate output, or state plainly what you could not verify.
5. **Verify APIs before you call them.** Never invoke a function / flag / option you are not sure exists with that signature. Check the repo, the dependency source, the docs — *first*. A hallucinated call costs far more than the 20-second check.
6. **Greenfield. No legacy.** Pre-release MVP: edit the original, delete the dead, update every caller in the same change. No shims, flags, or "v2" for behavior nobody depends on yet.
7. **Leave it cleaner than you found it — the boy-scout rule.** When you're already in a file and see a small, safe improvement — a misleading name, dead code, a missing *why* comment, a shape that's now obviously clumsy — fix it as you pass through; don't step over a mess. The limit is the *focused commit*: only when the cleanup is large, risky, or would sprawl the diff into a second story do you defer it — capture it as a task in `BACKLOG.md` and move on, never silently drop it. The test: would a reviewer thank you for the tidy, or wince at an unrelated refactor smuggled into the commit?

---

## The `.agent/` working state (per project)

Each project has an `.agent/` folder — durable working memory the BOOT protocol reads back. **Only `rules/` (the shared taste KB) and `scripts/` (maintained dev tooling) are committed; everything else here is local working state and git-ignored** — the queue, log, ideas, backlog, and decisions stay on the machine, so they never create commit noise or cross-agent merge conflicts. Files:

- **`TASKS.md`** — the work queue. Four states, nothing else, so skipped work has nowhere to hide:
  - `[ ]` todo · `[w]` **claimed / in progress** · `[x]` **done _and_ gated-green _and_ committed** · `[B]` blocked.
  - A `[B]` item **must** have a matching entry in `PENDING_DECISIONS.md`. `[w]` is a soft claim so two agents working in parallel don't grab the same task (see the work loop). Every task is always exactly one of these four — you never silently drop or half-finish one.
- **`BACKLOG.md`** — actionable work you *discover* outside the current task's scope and **too big to fix on the spot**: a bug, tech debt, a missing test, a refactor you shouldn't do right now. (A small, safe cleanup you *can* do as you pass through, you just do — boy-scout rule, creed #7 — no entry needed; `BACKLOG` is for what would derail the current task.) Capture it here the moment you see it — don't derail the current goal, don't lose the finding — then keep going. **Not auto-worked**, and **not scanned by the Stop hook**, so it never blocks a batch; a human (or a later, deliberate pass) promotes an item into `TASKS.md` → `## Active`. (Distinct from `IDEAS.md` = product features needing approval, and `PENDING_DECISIONS.md` = needs a human call.)
- **`LOG.md`** — your chain-of-thought, so the *what + why* survives compaction. Append a short entry when you make a decision, finish a task, or set yourself a next step. Newest first under `## Recent`; when `## Recent` passes ~50 lines, move older entries to `LOG.archive.md`. **Not committed** — it is local working memory (git-ignored).
- **`PENDING_DECISIONS.md`** — anything you can't do without a human call (a product decision, an ambiguous spec, a one-way-door migration). Write: the decision needed · the options · your recommendation. Mark the task `[B]` and move on. Never guess on an irreversible choice.
- **`IDEAS.md`** — product ideas as short implementation sketches. **Never auto-implemented.** A human details and approves an idea first; only then is it *moved* into `TASKS.md`. The work loop reads `TASKS.md` only — it never pulls work from `IDEAS.md`.
- **`rules/`** — the taste knowledge base, **the one committed part of `.agent/`** (shared across the team and both tools; see *The taste pipeline* below).

### Definition of Done

A task becomes `[x]` only when **all** of these hold:

- the project gate ran **green** (exact command in the project `AGENTS.md`),
- the change is **committed** — one focused commit per task,
- `LOG.md` has an entry.

No changelog file — `git log` is the changelog.

### The work loop (what `/sweep`, `/goal`, `/loop`, `/work` all follow)

Work the first `[ ]` in `TASKS.md`, then the next, until none remain:

1. **Claim** — flip `[ ]` → `[w]` with an edit (it fails safe if another agent changed the file first; on a collision, re-read and take the next `[ ]`). A parallel agent skips `[w]`, so you won't both grab the same task.
2. **Do it** — wear the hats; obey the project's `AGENTS.md`.
3. **Gate** — run the project gate; fix until green.
4. **Commit** — one focused commit for the task.
5. **Record** — append a *what + why* line to `LOG.md`, flip `[w]` → `[x]`, and move to the next `[ ]`.

When the loop is interrupted:

- **Blocked?** Mark `[B]` and write the `PENDING_DECISIONS.md` entry; move on.
- **Abandoning a claim?** Set it back to `[ ]` so it gets picked up.
- **Spot something off** — a bug, debt, a missing test, a small mess? **Fix it in place when it's a small, safe cleanup** (boy-scout rule, creed #7); when it's bigger, risky, or would derail/sprawl the commit, jot it in `BACKLOG.md` and stay on the current task. Capture what you don't fix; never walk past a mess.

**Don't-stop contract:** never stop holding a `[w]`, and do not stop while an actionable `[ ]` remains (`[w]`/`[x]`/`[B]` don't block the Stop hook — a `[w]` is some agent's live claim). At the end of a batch, re-verify every `[x]` against `git log`, and reclaim any orphaned `[w]` left by an interrupted session (set it back to `[ ]`).

---

## The taste pipeline — learn the house style, durably

When the user corrects something — a naming call, a "use X not Y," a structural nit — it is a **rule**, not a one-off fix. In the **same change**:

1. **Fix** the flagged instance.
2. **Record** the rule: a one-line entry in the project `AGENTS.md` rule index, plus — when it needs worked examples — a `rules/<slug>.md` file (*rule · why · ✅ good · ❌ bad · how it's enforced*).
3. **Sweep** the codebase for other instances of the old shape and fix them too.
4. **Graduate** it: if the rule is mechanically checkable, add an automated check so it can't regress — portal → an `Emisar.Checks.*` Credo check (wired into `.credo.exs`, fixture-verified to fire); Go → `go vet` / a linter / a hook.

A correction that only fixes the flagged line *will* be repeated. This pipeline exists to prevent exactly that.

---

## One setup, two tools (Claude + Codex)

**Governing principle:** all durable knowledge and state live in tool-neutral files at fixed paths — `AGENTS.md` and `.agent/`. Each tool's native config is a **thin wrapper that points into those files, never a copy.**

- **Instructions** — `AGENTS.md` is canonical. Codex reads it natively; Claude reads it through the `CLAUDE.md` symlink at each level (root + every project).
- **State + rules** — `.agent/` is read and written identically by both tools.
- **Skills / commands** — one source: `.claude/skills/`. Claude reads it natively; Codex reads the **same files** via the `.codex/skills` → `../.claude/skills` symlink (Codex auto-discovers a project-level `.codex/skills/` and ignores Claude's extra frontmatter). No per-tool skill copies.
- **Enforcement** — Claude hooks under `.claude/` (Stop, commit-gate); the *logic* lives in shared scripts so CI or another tool can reuse it. This layer is genuinely per-tool (Codex has no hook equivalent) — never duplicate *knowledge* into it.

---

## Skills & hats

Two kinds:

- **Generic hats** — `/product-manager`, `/ux-designer`, `/security-engineer`, `/seo-marketing`, `/spec`, `/work` — apply repo-wide regardless of language. Wear one when a change leans hard on its domain.
- **Per-product engineering skills** — language-specific. The Elixir set (`/context-fn`, `/new-context`, `/iron-review`, `/oban`, `/perf`, `/testing`, …) is **portal-only**. Go work in `runner/`/`mcp/` uses the Go engineering skill plus that project's `AGENTS.md`.

For a thorough pre-merge review, **`/review-board`** convenes the relevant hats above as parallel review subagents and synthesizes one ranked verdict + a prioritized fix plan — it supersedes running `/security-review`, `/code-review`, and `/ship-review` separately, and the fix plan can be queued straight into `.agent/TASKS.md` for `/sweep`.

Skills are thin entry points — the durable rules they apply live in `AGENTS.md` and `.agent/rules/`. Both tools share the **same** skill files: Claude via `.claude/skills/`, Codex via the `.codex/skills` → `../.claude/skills` symlink (auto-discovered when Codex runs in the repo).

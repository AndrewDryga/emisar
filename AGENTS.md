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

Three products, each with its own `AGENTS.md` + `.agent/`:

| Project | Language | What it is | Read before editing |
|---|---|---|---|
| `portal/` | Elixir / Phoenix | the control plane (web, MCP, policy, approvals, audit, billing) | `portal/AGENTS.md` |
| `runner/` | Go | the on-host runner that executes actions | `runner/AGENTS.md` |
| `mcp/` | Go | the stdio↔HTTP MCP bridge for LLM clients | `mcp/AGENTS.md` |

---

## The creed — how we build (every project)

Generalize from these; defer to the project `AGENTS.md` for specifics.

1. **Pragmatic. Boring solutions that work.** Reach for the dull, proven shape first. Clever earns its place only when boring genuinely can't do the job — and you can say *why* in one sentence. No frameworks-within-the-framework, no speculative abstraction.
2. **We ship a good, _sellable_ product.** Every change serves a real operator need. Wear the hats before writing code — **PM** (is this the right thing to build, or should it be cut or smaller?), **UX** (is the operator's path obvious; are the empty / error / loading / offline states handled?), **Security** (what's the abuse case?), **Marketing** (does this make the product easier to explain and sell?), **Maintainer** (will this read clearly in six months?). Care about product, quality, UX, and marketing *genuinely* — but pragmatically: a half-built "platform" sells nothing; a small thing done well does.
3. **Readable code, no bloat.** Match the surrounding style exactly. Delete more than you add when you can. No config knobs nobody asked for, no "just in case" parameters, no comments narrating *what* — comments say *why*.
4. **Done means verified, not done-once.** A change is done when it compiles clean, is formatted, passes its gate, is covered by tests (including the denial / abuse path where it applies), and is obvious — not when it ran once. Never say "should work"; show the gate output, or state plainly what you could not verify.
5. **Verify APIs before you call them.** Never invoke a function / flag / option you are not sure exists with that signature. Check the repo, the dependency source, the docs — *first*. A hallucinated call costs far more than the 20-second check.
6. **Greenfield. No legacy.** Pre-release MVP: edit the original, delete the dead, update every caller in the same change. No shims, flags, or "v2" for behavior nobody depends on yet.

---

## The `.agent/` working state (per project)

Each project has an `.agent/` folder — durable working memory the BOOT protocol reads back. Files:

- **`TASKS.md`** — the work queue. Three states, nothing else, so skipped work has nowhere to hide:
  - `[ ]` todo · `[x]` **done _and_ gated-green _and_ committed** · `[B]` blocked.
  - A `[B]` item **must** have a matching entry in `PENDING_DECISIONS.md`. There is no fourth state — you never silently drop or half-finish a task.
- **`LOG.md`** — your chain-of-thought, so the *what + why* survives compaction. Append a short entry when you make a decision, finish a task, or set yourself a next step. Newest first under `## Recent`; when `## Recent` passes ~50 lines, move older entries to `LOG.archive.md`. **Not committed** — it is local working memory (git-ignored).
- **`PENDING_DECISIONS.md`** — anything you can't do without a human call (a product decision, an ambiguous spec, a one-way-door migration). Write: the decision needed · the options · your recommendation. Mark the task `[B]` and move on. Never guess on an irreversible choice.
- **`IDEAS.md`** — product ideas as short implementation sketches. **Never auto-implemented.** A human details and approves an idea first; only then is it *moved* into `TASKS.md`. The work loop reads `TASKS.md` only — it never pulls work from `IDEAS.md`.
- **`rules/`** — the taste knowledge base (see *The taste pipeline* below).

### Definition of Done

A task becomes `[x]` only when ALL hold: the project gate ran **green** (exact command is in the project `AGENTS.md`), the change is **committed** (one focused commit per task), and `LOG.md` has an entry. No changelog file — `git log` is the changelog.

### The work loop (what `/goal`, `/loop`, `/work` all follow)

Pick the first `[ ]` in `TASKS.md` → do it (wear the hats; obey the project `AGENTS.md`) → run the gate → fix until green → commit → append to `LOG.md` → tick `[x]` → next. If blocked: write `PENDING_DECISIONS.md`, mark `[B]`, continue to the next `[ ]`. **Do not stop while an actionable `[ ]` remains.** At the end of a batch, re-verify every `[x]` you claimed against `git log` — eyeball passes miss work.

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
- **Enforcement** (Claude hooks under `.claude/`) and **commands** (Claude skills under `.claude/skills/`, Codex prompts) are per-tool wrappers: the *logic* lives in shared scripts (the project gate, the hooks) and the *knowledge* in `.agent/` + `AGENTS.md`. Never duplicate knowledge into a tool-specific file.

---

## Skills & hats

Two kinds:

- **Generic hats** — `/product-manager`, `/ux-designer`, `/security-engineer`, `/seo-marketing`, `/plan`, `/work` — apply repo-wide regardless of language. Wear one when a change leans hard on its domain.
- **Per-product engineering skills** — language-specific. The Elixir set (`/context-fn`, `/new-context`, `/iron-review`, `/oban`, `/perf`, `/testing`, …) is **portal-only**. Go work in `runner/`/`mcp/` uses the Go engineering skill plus that project's `AGENTS.md`.

Skills are thin entry points — the durable rules they apply live in `AGENTS.md` and `.agent/rules/`, so a Codex prompt can point at the same knowledge.

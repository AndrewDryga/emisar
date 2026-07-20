# emisar — how we work (canonical agent manual)

`emisar` is a control plane for AI-safe infrastructure actions: operators — and LLMs via MCP — dispatch **gated, audited** actions to a fleet of on-host runners. **It is a security product.** Treat every surface that ingests runner / LLM / operator input as hostile until proven otherwise.

This file is the **canonical, tool-neutral operating manual** for any AI agent (Claude Code, Codex, …) working in this repo. `CLAUDE.md` is a symlink to it. Read it top to bottom — it is deliberately small; the deep, per-language rules live in each project's own `AGENTS.md`.

---

## ⟢ BOOT — read this when you start, or lose context

Context compaction drops everything except this file (re-injected from disk) and your tool's memory. When you start fresh, resume after a compaction, or feel unsure what you were doing, **re-read in this order before touching code**:

1. **This file** — the creed + the contract below.
2. **The project's `AGENTS.md`, in full** — not a skim. The rules are non-negotiable and you *will* violate them from memory.
3. **`.agent/kb/README.md`'s index** — the descriptive knowledge base's routing table. Open a card only when your task touches its subsystem; never bulk-load the kb.
4. **`<project>/.agent/tasks/`** — the work queue (run `coop tasks`; it reads `.agent/tasks/`). Resume the first todo or in_progress task: read its `state.md` FIRST (the overwritten resume snapshot — where it stopped, the next action, traps), then its `log.md` (the append-only why-journal). That pair is how intent survives a compaction or a fresh box.

Five top-level areas, each with its own `AGENTS.md`:

| Project | Language | What it is | Read before editing |
|---|---|---|---|
| `portal/` | Elixir / Phoenix | the control plane (web, MCP, policy, approvals, audit, billing) | `portal/AGENTS.md` |
| `runner/` | Go | the on-host runner that executes actions | `runner/AGENTS.md` |
| `mcp/` | Go | the stdio↔HTTP MCP bridge for LLM clients | `mcp/AGENTS.md` |
| `packs/` | YAML | the action-pack catalog — what runners may execute | `packs/AGENTS.md` |
| `infra/` | Terraform | the Google Cloud production stack (compute, Cloud SQL, LB, DNS, secrets, monitoring) | `infra/AGENTS.md` |

---

## The creed — how we build (every project)

Generalize from these; defer to the project `AGENTS.md` for specifics.

1. **Pragmatic. Boring solutions that work.** Reach for the dull, proven shape first. Clever earns its place only when boring genuinely can't do the job — and you can say *why* in one sentence. No frameworks-within-the-framework, no speculative abstraction.
2. **We ship a good, _sellable_ product.** Every change serves a real operator need. Wear the hats before writing code — **PM** (is this the right thing to build, or should it be cut or smaller?), **UX** (is the operator's path obvious; are the empty / error / loading / offline states handled?), **Security** (what's the abuse case?), **Marketing** (does this make the product easier to explain and sell?), **Maintainer** (will this read clearly in six months?). Care about product, quality, UX, and marketing *genuinely* — but pragmatically: a half-built "platform" sells nothing; a small thing done well does.
3. **Readable code, no bloat.** Match the surrounding style exactly. Delete more than you add when you can. No config knobs nobody asked for, no "just in case" parameters, no comments narrating *what* — comments say *why*.
4. **Done means verified, not done-once.** A change is done when it compiles clean, is formatted, passes its gate, is covered by tests (including the denial / abuse path where it applies), and is obvious — not when it ran once. Never say "should work"; show the gate output, or state plainly what you could not verify.
5. **Verify APIs before you call them.** Never invoke a function / flag / option you are not sure exists with that signature. Check the repo, the dependency source, the docs — *first*. A hallucinated call costs far more than the 20-second check.
6. **Greenfield. No legacy.** Pre-release MVP: edit the original, delete the dead, update every caller in the same change. No shims, flags, or "v2" for behavior nobody depends on yet. **The one exception is a committed DB migration — it has already run in prod and is FROZEN: never edit or delete it, add a new migration** (editing it diverges prod's schema and takes prod down; the commit-gate enforces this — see the project `AGENTS.md` §8). **A second freeze arrives at 1.0: the public compatibility surfaces** — the runner↔portal wire protocol, the pack/catalog/manifest schemas, the MCP tool surface, the runner/mcp CLIs + config + env, the install scripts, and the registry URL layout — **become frozen the way a committed migration is** (a deployed peer or a saved operator config already depends on them): from 1.0 you never edit, rename, or reinterpret one in place — add a versioned successor or follow the deprecation path in [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md). Pre-1.0 they are still greenfield; that document maps what will freeze.
7. **Leave it cleaner than you found it — the boy-scout rule.** When you're already in a file and see a small, safe improvement — a misleading name, dead code, a missing *why* comment, a shape that's now obviously clumsy — fix it as you pass through; don't step over a mess. The limit is the *focused commit*: only when the cleanup is large, risky, or would sprawl the diff into a second story do you defer it — capture it (simple and ready → `coop tasks add`; big or unscoped → `coop backlog add`) and move on, never silently drop it. The test: would a reviewer thank you for the tidy, or wince at an unrelated refactor smuggled into the commit?
8. **CI validates; CD delivers.** `.github/workflows/ci.yml` runs on pull requests and as a reusable workflow. Main-only `.github/workflows/cd.yml` calls that exact file from the same commit, then publishes its tested artifacts and queues deployment. Write/OIDC permissions, environments, and deployment secrets belong only in CD — never in PR-triggered CI. A human release gate and its publisher are separate jobs: stale waiting approvals may be superseded, but an active publication is serialized and never canceled mid-write. Manual HCP applies use provisional configuration versions and saved plans; standard unconfirmed plans hold the workspace lock and do not belong in CD. CI checks real behavior, security boundaries, and plausible regression paths; never add a source grep solely to police an architectural placement rule.

---

## The `.agent/` working state (per project)

Each project has an `.agent/` folder — durable working memory the BOOT protocol reads back. **The knowledge and config are committed — `rules/` (the taste KB), `kb/` (the descriptive KB), `presets/` (orchestration recipes), `scripts/` (maintained dev tooling), and the root `project.yaml`, `loop.yaml`, and `compose.yml`; everything else is local working state and git-ignored** — the queue, backlog drawer, log, and decisions stay on the machine, so they never create commit noise or cross-agent merge conflicts. Files:

- **`tasks/`** — the work queue: **a folder per task**, driven by `coop tasks`. A task's **state is its directory**, four states, nothing else, so skipped work has nowhere to hide:
  - `00_todo/` todo · `10_in_progress/` **claimed / in progress** · `50_blocked/` blocked · `99_done/` **done _and_ gated-green _and_ committed**. The numeric prefix just sorts `ls` in lifecycle order; a state change is a **folder move**, never a checkbox edit — always via `coop tasks`, never a manual `mv`.
  - Each task is `.agent/tasks/<state>/<id>/task.md` (+ optional `log.md`/`state.md`, and `decision.md` for a blocked task). `coop tasks ls` shows them by state; `coop tasks add "<title>"` queues one. A `50_blocked/` task **must** carry its own `decision.md` (`coop tasks block` writes the stub). `10_in_progress/` is a soft claim so two agents in parallel don't grab the same task (see the work loop). Every task is always exactly one of these four — you never silently drop or half-finish one.
- **`tasks/xx_backlog/`** — the backlog DRAWER (`coop backlog`): work you *discover* that is **big or not-yet-ready** — it needs a spec, a decision, or real scoping before anyone can work it. Capture it the moment you see it (`coop backlog add "<title>"`) and keep going — don't derail the current goal, don't lose the finding. A simple, ready fix you can state in a line goes straight to the queue (`coop tasks add`) instead — the backlog is not a dumping ground for small stuff. (A small, safe cleanup you *can* do as you pass through, you just do — boy-scout rule, creed #7 — no entry needed.) The drawer lives OUTSIDE the lifecycle: **never auto-worked**, not scanned by the Stop hook, ignored by every counter; `coop backlog promote <id>` moves an item into `00_todo/` once it's fleshed out. Product ideas that need founder review live here too — write the sketch in the idea's `task.md` and mark it as needing approval; only a human promotes those.
- **`LOG.md`** — your chain-of-thought, so the *what + why* survives compaction. Append a short entry when you make a decision, finish a task, or set yourself a next step. Newest first under `## Recent`; when `## Recent` passes ~50 lines, move older entries to `LOG.archive.md`. **Not committed** — it is local working memory (git-ignored).
- **A blocked task's `decision.md`** — **only a genuine _human call_**: a product decision, an ambiguous spec, an irreversible one-way-door migration. `coop tasks block <id>` moves the task to `50_blocked/` and writes the `decision.md` stub; fill it in — the decision needed · the options · your recommendation — then move on (`coop tasks decisions` lists the open ones). Never guess on an irreversible choice. **"Blocked on evidence / verification" is NOT a human call and must NEVER block a task** — needing to know an API's shape, a CLI verb's behaviour on recent versions, a live system's cert path, or whether something reproduces is *work you do*, not a decision someone else makes. **Gather the evidence yourself** — spawn a subagent, stand up a throwaway Docker SUT, query the live MCP fleet, or read a sibling repo (e.g. `../blitz/blitz-infra`) — then proceed. A blocked task whose blocker is "we don't know X yet" is a mis-file: go find out X.
- **`rules/`** — the taste knowledge base, NORMATIVE ("do X, not Y"), committed (shared across the team and both tools; see *The taste pipeline* below).
- **`kb/`** — the DESCRIPTIVE knowledge base, committed: subsystem maps, cross-cutting traps, gotchas the code doesn't obviously carry. A self-improving wiki you maintain directly — when a task teaches you something non-obvious about a subsystem, add or update its card **in the same commit as the work**. Read `kb/README.md` for the card format and reading protocol (index at boot; a card only when your task touches its subsystem).
- **`presets/`** — orchestration recipes (committed): which agent leads and which roles it routes to. See *Orchestration* below.
- **`loop.yaml`** — the `coop loop` configuration (committed): the work ladder, the per-task audit between iterations, and the final signoff.

### Definition of Done

A task moves to `99_done/` (via `coop tasks done`) only when **all** of these hold:

- the project gate ran **green** (exact command in the project `AGENTS.md`),
- the change is **committed** — one focused commit per task, carrying its `Coop-Task: <id>` trailer,
- the task's own `log.md` says *why* (decisions, dead ends — the audit and the next agent read it), and its `state.md` reflects the finished state.

No changelog file — `git log` is the changelog.

### The work loop (what `/workflow-sweep`, `/goal`, `/loop`, `/workflow-work` all follow)

Work the first todo task in `.agent/tasks/` (`coop tasks ls`), then the next, until none remain:

1. **Claim** — `coop tasks claim <id>` (moves it `00_todo/` → `10_in_progress/`). A parallel agent skips `10_in_progress/`, so you won't both grab the same task.
2. **Do it** — wear the hats; obey the project's `AGENTS.md`.
3. **Gate** — run the project gate; fix until green.
4. **Commit** — one focused commit for the task, ending with a `Coop-Task: <id>` trailer (the id is the task's folder name). The trailer binds the commit to its task — it's how coop resumes correctly after an interruption between commit and folder-move, and reconciles the queue after a fork merge. (Never cite that commit by SHA in task notes — coop re-signs box commits on the host, which rewrites SHAs; cite the task id.)
5. **Record** — update the task's `log.md` (*what + why*, append-only) and overwrite its `state.md` with the final snapshot, then `coop tasks done <id>` (moves it to `99_done/`), and move to the next todo task.

When the loop is interrupted:

- **Blocked?** Only if it's a true **human call** (above): `coop tasks block <id>` + fill in its `decision.md`; move on (`coop tasks unblock <id>` returns it to `00_todo/` once decided; claim it again before work). If the blocker is *missing evidence* (a live check, an API shape, "does this verb still work"), it is **not** blocked — gather the evidence yourself (subagent / throwaway SUT / live fleet / sibling repo) and keep going.
- **Abandoning a claim?** Move it back to `00_todo/` so it gets picked up.
- **Spot something off** — a bug, debt, a missing test, a small mess? **Fix it in place when it's a small, safe cleanup** (boy-scout rule, creed #7); when it's bigger, capture it — simple and ready → `coop tasks add`; big or needing a spec → `coop backlog add` — and stay on the current task. Capture what you don't fix; never walk past a mess.

**Don't-stop contract:** never stop holding an in_progress task, and do not stop while an actionable todo remains (`10_in_progress/`/`99_done/`/`50_blocked/` don't block the Stop hook — an in_progress task is some agent's live claim). At the end of a batch, re-verify every `99_done/` task against `git log`, and reclaim any orphaned `10_in_progress/` task left by an interrupted session (move it back to `00_todo/`).

---

## Orchestration — spend the big model where it matters

The repo's orchestration recipe is the **frontier preset** (`.agent/presets/frontier/preset.yaml`):
a cross-vendor lead ladder (Fable 5 ⇄ GPT-5.6 Sol at max effort, failing over on rate limits) with
three roles. Run it interactively (`coop frontier`) or unattended (`coop loop` — configured by
`.agent/loop.yaml`: work under the preset, a fast-tier audit after each finished task, a cross-vendor
signoff at the end). When you lead, you orchestrate: plan, decompose, synthesize, make the final
calls, and keep your own context lean by routing:

- **thinker** (consult, read-only — codex terra at xhigh) — architecture calls, intermittent bugs,
  security, and a pre-commit review of trust-boundary changes. Self-contained prompt:
  `coop-consult thinker --fresh "…"`; it returns a conclusion, you act on it.
- **critic** (consult, read-only — grok, the third vendor) — plan review, tradeoffs, one-way doors:
  frozen migrations, wire/protocol formats, pack manifest semantics, billing.
  `coop-consult critic --fresh "…"`.
- **fast** (delegate, write-capable — codex luna at xhigh) — mechanical, fully-specified work:
  boilerplate, bulk edits, test scaffolding, repo surveys. `coop-delegate fast`; it never commits —
  you review its diff, run the touched project's gate, and commit.
- **High-stakes decisions:** task the thinker AND the critic in parallel with the same neutral
  problem statement — never showing either the other's answer — then synthesize the best of both.

Outside the preset (no `coop-consult`/`coop-delegate` on PATH), use your runtime's own subagents for
the same split — reasoning vs mechanical — and skip peers. **Single-writer rule regardless:** advisors
and peers think; exactly ONE agent edits this checkout, gates, and commits. Parallel implementation
goes through `coop fork` (each fork is its own clone) — never two writers in one tree.

---

## The taste pipeline — learn the house style, durably

### Rule index

- **Content:** [plain, specific prose](.agent/rules/content-plain-specific-prose.md) — write for one known reader, make every sentence earn its place, and adapt the density and tone to the surface instead of falling back to corporate or generated language.
- **Content:** [bounded autonomy leads the positioning](.agent/rules/content-position-bounded-autonomy.md) — lead with the agent work the operator can safely leave running; earn that promise with declared actions, the pack catalog, and enforcement, while keeping approvals and audit in their supporting role.
- **Content:** [repository maps come from the tree](.agent/rules/content-repository-maps-come-from-the-tree.md) — inspect the actual files, commands, and owner docs before summarizing a repository area; preserve production status and every primary responsibility.
- **Content:** [guides teach; the chrome sells](.agent/rules/content-guides-teach-not-sell.md) — a `/guides/*` piece argues with zero in-body product mentions (or one designated section); a product-docs link mid-argument is the genre flip that turns teaching into a brochure, and the page chrome carries the conversion.
- **Infra:** [optional-resource refs use splat, never a hard index](.agent/rules/infra-optional-resource-splat-refs.md) — a consumer that can outlive a count-gated resource references it as `A[*].attr` so absence degrades to `[]`; `A[0].attr` bakes in existence and turns a lifecycle flip into graph surgery.
- **Runner:** [host readiness stays separate from descriptors](.agent/rules/runner-host-readiness-separate-from-descriptors.md) — preserve complete trusted-manifest comparison and report mutable host readiness as subtractive deployment evidence.
- **Shared:** [solve the owned problem, not the general one](.agent/rules/shared-solve-the-owned-problem.md) — first-party inputs get authoring-time lints, never runtime exactness subsystems; pre-1.0 single-release deployments get no rollout barriers, dual formats, or never-shipped-peer handshakes; a new validation choke point deletes the checks it shadows in the same change.
- **Shared:** [reversible and terminal runner states stay distinct](.agent/rules/shared-runner-lifecycle-states.md) — disable keeps the identity retryable so enable recovers without host access; delete/revoke is terminal and never inherits retry behavior.

When the user corrects something — a naming call, a "use X not Y," a structural nit — it is a **rule**, not a one-off fix. In the **same change**:

1. **Fix** the flagged instance.
2. **Record** the rule **as a general shape — the pattern to recognize plus the fix — never a description of the one function you just fixed.** A rule pinned to a single function (`fetch_and_lock_account does X`) teaches nothing transferable and can't drive step 3; the same rule stated generally (*single-row reads return their tuple via `Repo.fetch`, never `Repo.one` + a hand-rolled nil-check*) both stops you writing it again anywhere and names exactly what to grep for. State the abuse case, give a sweep target. A one-line entry in the project `AGENTS.md` rule index, plus — when it needs worked examples — a domain-prefixed `rules/<domain>-<slug>.md` file (*rule · why · ✅ good · ❌ bad · how it's enforced*).
3. **Sweep** the codebase for other instances of the old shape and fix them too — the generally-stated rule from step 2 is what makes this a mechanical pass rather than a guess.
4. **Graduate** it: if the rule is mechanically checkable, add an automated check so it can't regress — portal → an `Emisar.Checks.*` Credo check (wired into `.credo.exs`, fixture-verified to fire); Go → `go vet` / a linter / a hook.

A correction that only fixes the flagged line *will* be repeated. This pipeline exists to prevent exactly that. Rule filenames are namespaced for discovery: `design-*` for visual/UX rules, `content-*` for writing/content rules, `elixir-*` for portal Elixir conventions, and `runner-*`, `mcp-*`, `packs-*`, `infra-*`, or `shared-*` for those domains. Never add a new bare rule filename.

---

## One setup, two tools (Claude + Codex)

**Governing principle:** all durable knowledge and state live in tool-neutral files at fixed paths — `AGENTS.md` and `.agent/`. Each tool's native config is a **thin wrapper that points into those files, never a copy.**

- **Instructions** — `AGENTS.md` is canonical. Codex reads it natively; Claude reads it through the `CLAUDE.md` symlink at each level (root + every project).
- **State + rules** — `.agent/` is read and written identically by both tools.
- **Contributor skills / commands** — one source: `.claude/skills/`. Claude reads it natively; Codex reads the **same files** via the `.codex/skills` → `../.claude/skills` symlink (Codex auto-discovers a project-level `.codex/skills/` and ignores Claude's extra frontmatter). No per-tool skill copies.
- **Customer skills** — public product artifacts live under `skills/<name>/`, use portable frontmatter and public interfaces, and never depend on a repository checkout, `AGENTS.md`, `.agent/`, internal contributor skills, or `.claude/` / `.codex/` discovery. `skills/README.md` owns direct customer installation.
- **Enforcement** — Claude hooks under `.claude/` (Stop, commit-gate); the *logic* lives in shared scripts so CI or another tool can reuse it. This layer is genuinely per-tool (Codex has no hook equivalent) — never duplicate *knowledge* into it.
- **Bookkeeping audit** — after changing `AGENTS.md`, `.claude/skills/`, `skills/`, `.codex/`, hooks, or task-queue conventions, run `bash .agent/scripts/audit-llm-setup.sh`. It checks the cross-tool symlinks, current `coop` verbs/state names, and contributor/customer skill metadata so stale agent instructions fail fast.

---

## Skills & hats

Two kinds:

- **Generic hats** — `/product-manager`, `/design-ux`, `/security-engineer`, `/content-seo`, `/workflow-spec`, `/workflow-work` — apply repo-wide regardless of language. Wear one when a change leans hard on its domain.
- **Per-product engineering skills** — language-specific. The Elixir set (`/elixir-context-fn`, `/elixir-new-context`, `/elixir-iron-review`, `/elixir-recurrent-jobs`, `/elixir-performance`, `/elixir-testing`, …) is **portal-only**. Go work in `runner/`/`mcp/` uses the Go engineering skill plus that project's `AGENTS.md`.

For a thorough pre-merge review, **`/review-board`** convenes the relevant hats above as parallel review subagents and synthesizes one ranked verdict + a prioritized fix plan. Use `/review-ship` for a lighter proportional review; the fix plan can be queued straight into `.agent/tasks/00_todo/` for `/workflow-sweep`.

Contributor skills are thin entry points — the durable rules they apply live in `AGENTS.md` and `.agent/rules/`. Both tools share those internal skill files: Claude via `.claude/skills/`, Codex via the `.codex/skills` → `../.claude/skills` symlink (auto-discovered when Codex runs in the repo). Customer-distributed skills are a separate public product surface under `skills/`; see `skills/README.md`.

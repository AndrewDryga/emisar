# emisar — how we work (canonical agent manual)

`emisar` is a control plane for AI-safe infrastructure actions: operators — and LLMs via MCP — dispatch **gated, audited** actions to a fleet of on-host runners. **It is a security product.** Treat every surface that ingests runner / LLM / operator input as hostile until proven otherwise.

This file is the **canonical, tool-neutral operating manual** for any AI agent (Claude Code, Codex, …) working in this repo. `CLAUDE.md` is a symlink to it. Read it top to bottom — it is deliberately small; the deep, per-language rules live in each project's own `AGENTS.md`.

---

## ⟢ BOOT — read this when you start, or lose context

Context compaction drops everything except this file (re-injected from disk) and your tool's memory. When you start fresh, resume after a compaction, or feel unsure what you were doing, **re-read in this order before touching code**:

1. **This file** — the creed + the contract below.
2. **The project's `AGENTS.md`, in full** — not a skim. The rules are non-negotiable and you *will* violate them from memory.
3. **`.agent/kb/README.md`'s index** — the durable-knowledge routing table. Open a descriptive card, specification, runbook, or rule only when your task touches its subsystem or operation; never bulk-load the KB. Everything outside `kb/internal/` is customer-safe/public. For marketing, positioning, launches, company operations, or other non-customer-facing work, use the gitignored `kb/internal/` subtree and only the relevant material already there.
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
6. **Greenfield. No legacy.** Pre-release MVP: edit the original, delete the dead, update every caller in the same change. No shims, flags, or "v2" for behavior nobody depends on yet. **The one exception is a committed DB migration — it has already run in prod and is FROZEN: never edit or delete it, add a new migration** (editing it diverges prod's schema and takes prod down; the commit-gate enforces this — see the project `AGENTS.md` §8). **A second freeze arrives at 1.0: the public compatibility surfaces** — the runner↔portal wire protocol, the pack/catalog/manifest schemas, the MCP tool surface, the OAuth/device-authorization, SSO/SCIM, and audit-export APIs, the runner/mcp CLIs + config + env, the install scripts, and the registry URL layout — **become frozen the way a committed migration is** (a deployed peer or a saved operator config already depends on them): from 1.0 you never edit, rename, or reinterpret one in place — add a versioned successor or follow the deprecation path in [`.agent/kb/specs/compatibility.md`](.agent/kb/specs/compatibility.md). Pre-1.0 they are still greenfield; that document maps what will freeze.
7. **Leave it cleaner than you found it — the boy-scout rule.** When you're already in a file and see a small, safe improvement — a misleading name, dead code, a missing *why* comment, a shape that's now obviously clumsy — fix it as you pass through; don't step over a mess. The limit is the *focused commit*: only when the cleanup is large, risky, or would sprawl the diff into a second story do you defer it — capture it (simple and ready → `coop tasks add`; big or unscoped → `coop backlog add`) and move on, never silently drop it. The test: would a reviewer thank you for the tidy, or wince at an unrelated refactor smuggled into the commit?
8. **CI validates; CD delivers.** `.github/workflows/ci.yml` runs on pull requests and as a reusable workflow. Main-only `.github/workflows/cd.yml` calls that exact file from the same commit, then publishes its tested artifacts and queues deployment. Write/OIDC permissions, environments, and deployment secrets belong only in CD — never in PR-triggered CI. A human release gate and its publisher are separate jobs: stale waiting approvals may be superseded, but an active publication is serialized and never canceled mid-write. Manual HCP applies use provisional configuration versions and saved plans; standard unconfirmed plans hold the workspace lock and do not belong in CD. CI checks real behavior, security boundaries, and plausible regression paths; never add a source grep solely to police an architectural placement rule.

---

## The repository command surface

`./run` at the repository root is the one contributor command for people, agents,
hooks, and CI. Start with `./run help`; use `./run help <check|test|gate|pack|ops>`
for a focused command map.

- **`test` is focused feedback.** Pass a Portal path/Mix selector, Go test args, a
  pack-name filter, or an installer target.
- **`check` is quick or specialized validation.** It is not the Definition of Done.
- **`gate` is complete verification.** Finish with `./run gate <project>` for every
  project touched, or `./run gate all` for the whole repository.
- **Direct `mix`, `go`, `terraform`, or Docker commands are for diagnosis.** They
  may narrow a failure while working, but never replace the canonical final gate.

Canonical gates are `./run gate portal`, `runner`, `mcp`, `packs`, `infra`, and
`tooling`. Public product interfaces remain separate: `install.sh`,
`install-mcp.sh`, `emisar`, `emisar-mcp`, and `packctl` are shipped to operators;
`./run` is repository-only.

---

## The `.agent/` working state (per project)

Each project has an `.agent/` folder — durable working memory the BOOT protocol reads back. **The public knowledge and config are committed — `kb/` (descriptive cards, versioned `specs/`, operational `runbooks/`, and normative `rules/`, excluding local `internal/`), `presets/` (orchestration recipes), narrowly project-owned agent-hook `scripts/` where required, and the root `project.yaml`, `loop.yaml`, and `Dockerfile`; everything else is local working state and git-ignored** — internal materials, the queue, backlog drawer, and decisions stay on the machine, so they never create commit noise or cross-agent merge conflicts. Shared human-and-agent commands enter through `./run`; reusable checks live under `tools/`. Files:

- **`tasks/`** — the work queue: **a folder per task**, driven by `coop tasks`. A task's **state is its directory**, four states, nothing else, so skipped work has nowhere to hide:
  - `00_todo/` todo · `10_in_progress/` **claimed / in progress** · `50_blocked/` blocked · `99_done/` **done _and_ gated-green _and_ committed**. The numeric prefix just sorts `ls` in lifecycle order; a state change is a **folder move**, never a checkbox edit. **On the host** make that move with `coop tasks`, never a manual `mv`. **Inside a coop box `coop` is not installed** — there you move the folder yourself, and that move IS the state change; the loop prompt says so too. Every `coop tasks …` command below is the host form; in a box, do the equivalent folder move.
  - Each task is `.agent/tasks/<state>/<id>/task.md` (+ optional `log.md`/`state.md`, and `decision.md` for a blocked task). `coop tasks ls` shows them by state; `coop tasks add "<title>"` queues one. A `50_blocked/` task **must** carry its own `decision.md` (`coop tasks block` writes the stub). `10_in_progress/` is a soft claim so two agents in parallel don't grab the same task (see the work loop). Every task is always exactly one of these four — you never silently drop or half-finish one.
  - **Disposable screenshots belong to the task.** Put UI proof and visual-audit captures in the owning task's `screenshots/` directory so the evidence follows the task into the archive and disappears when done tasks are cleared. Before capturing, ensure a relevant task is in `10_in_progress/`; when none exists, create and claim a basic task first. `./run shot` and `./run capture console` select the sole active task automatically; pass `--task <id>` when several are active and `--group <name>` to organize a task-local capture set. Committed product images generated by `./run capture docs` are the exception.
- **`tasks/xx_backlog/`** — the backlog DRAWER (`coop backlog`): work you *discover* that is **big or not-yet-ready** — it needs a spec, a decision, or real scoping before anyone can work it. Capture it the moment you see it (`coop backlog add "<title>"`) and keep going — don't derail the current goal, don't lose the finding. A simple, ready fix you can state in a line goes straight to the queue (`coop tasks add`) instead — the backlog is not a dumping ground for small stuff. (A small, safe cleanup you *can* do as you pass through, you just do — boy-scout rule, creed #7 — no entry needed.) The drawer lives OUTSIDE the lifecycle: **never auto-worked**, not scanned by the Stop hook, ignored by every counter; `coop backlog promote <id>` moves an item into `00_todo/` once it's fleshed out. Product ideas that need founder review live here too — write the sketch in the idea's `task.md` and mark it as needing approval; only a human promotes those.
- **A blocked task's `decision.md`** — **only a genuine _human call_**: a product decision, an ambiguous spec, an irreversible one-way-door migration. `coop tasks block <id>` moves the task to `50_blocked/` and writes the `decision.md` stub; fill it in — the decision needed · the options · your recommendation — then move on (`coop tasks decisions` lists the open ones). Never guess on an irreversible choice. **"Blocked on evidence / verification" is NOT a human call and must NEVER block a task** — needing to know an API's shape, a CLI verb's behaviour on recent versions, a live system's cert path, or whether something reproduces is *work you do*, not a decision someone else makes. **Gather the evidence yourself** — spawn a subagent, stand up a throwaway Docker SUT, query the live MCP fleet, or read a sibling repo (e.g. `../blitz/blitz-infra`) — then proceed. A blocked task whose blocker is "we don't know X yet" is a mis-file: go find out X.
- **`kb/`** — the single home for durable repository knowledge. Cards directly under it are DESCRIPTIVE current-system facts: when implementation changes, its affected card changes too. `kb/specs/` contains versioned interface and security contracts; `kb/runbooks/` contains ordered maintainer procedures; `kb/rules/` contains NORMATIVE constraints a change must obey. All are customer-safe/public. Machine-readable contracts stay with their owning implementation and published integration files stay in explicitly tracked subtrees under `dist/`; generated `dist/` siblings remain ignored. The gitignored `kb/internal/` subtree holds local marketing materials and other company working knowledge that must not feed a customer-facing surface without explicit review; it is an audience boundary, never a place for secrets or customer data. Read `kb/README.md` for the decision test, audience boundary, and on-demand reading protocol.
- **`presets/`** — orchestration recipes (committed): which agent leads and which roles it routes to. See *Orchestration* below.
- **`loop.yaml`** — the `coop loop` configuration (committed): the work ladder, the per-task audit between iterations, and the final signoff.

### Definition of Done

A task moves to `99_done/` (via `coop tasks done`) only when **all** of these hold:

- the project gate ran **green** (exact command in the project `AGENTS.md`),
- the change is **committed** — one focused commit per task, carrying its `Coop-Task: <id>` trailer,
- the task's own `log.md` says *why* (decisions, dead ends — the audit and the next agent read it), and its `state.md` reflects the finished state.

No changelog file — `git log` is the changelog.

### The work loop (what `/workflow-sweep`, `/goal`, `/loop`, `/workflow-work` all follow)

Work the first todo task in `.agent/tasks/` (`coop tasks ls`), then the next, until none remain (in a box, read the queue directories directly and move folders by hand — see above):

1. **Claim** — `coop tasks claim <id>` (moves it `00_todo/` → `10_in_progress/`). A parallel agent skips `10_in_progress/`, so you won't both grab the same task.
2. **Do it** — wear the hats; obey the project's `AGENTS.md`.
3. **Gate** — run the project gate in the foreground and read its exit; fix until green. (In a box, a backgrounded gate dies with your turn — see the orchestration rule.)
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
a cross-vendor lead ladder (Fable 5 ⇄ GPT-5.6 Sol, failing over on rate limits) with three roles.
Run it interactively (`coop frontier`) or unattended (`coop loop` — configured by
`.agent/loop.yaml`: work under the preset, a fast-tier audit after each finished task, a
signoff at the end). When you lead, you orchestrate: plan, decompose, synthesize, make the final
calls, and keep your own context lean by routing:

- **thinker** (consult, read-only — codex Sol) — architecture calls, intermittent bugs,
  security, and a pre-commit review of trust-boundary changes. Self-contained prompt:
  `coop-consult thinker --fresh "…"`; it returns a conclusion, you act on it.
- **critic** (consult, read-only — codex Sol) — plan review, tradeoffs, one-way doors:
  frozen migrations, wire/protocol formats, pack manifest semantics, billing.
  `coop-consult critic --fresh "…"`.
- **fast** (delegate, write-capable — claude Opus, failing over to codex Luna) — mechanical,
  fully-specified work: boilerplate, bulk edits, test scaffolding, repo surveys.
  `coop-delegate fast`; it never commits — you review its diff, run the touched project's gate,
  and commit.
- **High-stakes decisions:** task the thinker AND the critic in parallel with the same neutral
  problem statement — never showing either the other's answer — then synthesize the best of both.
  Both consult roles currently run the SAME model, so this buys two dockets and two prompts, not
  two independent judgments; when a decision genuinely needs vendor independence, point one role
  at another vendor first (`.agent/presets/frontier/preset.yaml`) rather than assuming you have it.
- **In a box, NEVER end your turn while a background job is still running — a gate, a consult,
  anything.** Ending the turn ends the box, and every backgrounded job dies with it: the next
  iteration re-claims the task from scratch, and the loop stalls toward its give-up cap having
  committed nothing (this burned five iterations on one task waiting on a consult, then another
  iteration waiting on a backgrounded gate + consult pair). Run long jobs in the foreground and
  read their result in the same turn. If something is too slow to wait for, proceed on your own
  review and say so in the task log — a finished commit beats a perfect answer that never returns.

Outside the preset (no `coop-consult`/`coop-delegate` on PATH), use your runtime's own subagents for
the same split — reasoning vs mechanical — and skip peers. **Single-writer rule regardless:** advisors
and peers think; exactly ONE agent edits this checkout, gates, and commits. Parallel implementation
goes through `coop fork` (each fork is its own clone) — never two writers in one tree.

---

## The taste pipeline — learn the house style, durably

### Rule index

- **Content:** [plain, specific prose](.agent/kb/rules/content-plain-specific-prose.md) — write for one known reader, make every sentence earn its place, and adapt the density and tone to the surface instead of falling back to corporate or generated language.
- **Content:** [say it once](.agent/kb/rules/content-say-it-once.md) — state each idea in its clearest place once; every later paragraph/callout/slogan must add something new (example, caveat, limit, link), never restate it — simple writing is understood on the first read, not forced in by repetition. The mirror shape is PREAMBLE: a sentence that only announces or counts the table/list/form directly below it, or a top-of-page disclaimer ruling out a confusion the reader does not have, is cut and the content starts.
- **Content:** [bounded autonomy leads the positioning](.agent/kb/rules/content-position-bounded-autonomy.md) — lead with the agent work the operator can safely leave running; earn that promise with declared actions, the pack catalog, and enforcement, while keeping approvals and audit in their supporting role; never narrow the scope to incidents or state a boundary as a missing capability.
- **Content:** [walkthroughs start where the operator starts](.agent/kb/rules/content-walkthroughs-start-where-the-operator-starts.md) — the first numbered step is the reader's first action in our product, and a console path we name is a link, never bold prose; a docs page cannot know the account slug, so add a slugless `/app/*` deep link rather than describe the path.
- **Content:** [command examples show the real output](.agent/kb/rules/content-docs-commands-show-real-output.md) — a docs command block shows the output the operator will read, at least the part they act on, in the muted output style; the text follows the command's real print format (source or a live run), never an invented shape, and long output is elided with a lone `…` line.
- **Content:** [third-party walkthroughs show every screen](.agent/kb/rules/content-provider-walkthroughs-show-every-screen.md) — one numbered step per screen the operator encounters, each shot captured after its option is selected or its field filled, with the target control outlined; look at every image before wiring it in.
- **Content:** [a command with OS-specific spellings switches, it does not stack](.agent/kb/rules/content-os-variants-switch-not-stack.md) — publish one panel with the shared OS switch in its header, one named tab per OS (Linux / Windows / macOS — never a merged "macOS / Linux" label, even when two share a spelling), defaulted from the request User-Agent; every spelling stays in the page so the switch stays a convenience, never a gate.
- **Content:** [docs navigation separates concepts and walkthroughs](.agent/kb/rules/content-docs-navigation-separates-concepts-and-walkthroughs.md) — when a docs group contains generic mechanism pages and vendor-specific setup guides, render them as labeled sibling sections with concepts first, without adding routes or breadcrumb depth.
- **Content:** [provider certification evidence is dated](.agent/kb/rules/content-provider-certification-evidence-is-dated.md) — every provider guide ends with a literal evidence footer; live-org/live-tenant wording and its date need durable proof of that verification, otherwise say the guide was reviewed, and the overview never exceeds a guide's own evidence — a recertification moves the footer and its exact marketing test together.
- **Content:** [docs provenance stays quiet and actionable](.agent/kb/rules/content-docs-provenance-stays-quiet-and-actionable.md) — review dates are quiet shared chrome, contribution actions appear only when their destination can complete the promised workflow, and provider evidence stays distinct from editorial freshness.
- **Content:** [repository maps come from the tree](.agent/kb/rules/content-repository-maps-come-from-the-tree.md) — inspect the actual files, commands, and owner docs before summarizing a repository area; preserve production status and every primary responsibility.
- **Content:** [guides teach; the chrome sells](.agent/kb/rules/content-guides-teach-not-sell.md) — vendor-neutral guides keep product mentions to one designated section while explicitly titled product explainers teach mechanisms and limits without repeated pitches; the page chrome carries the conversion.
- **Content:** [console teaches in place; docs explain in depth](.agent/kb/rules/content-console-teaches-docs-explain.md) — a console surface orients in a sentence or two, speaks to the operator rather than about our design (no term definitions, no justifying a restriction, no naming the attack it prevents, no first-person implementation), and links the one docs page that owns its subject; mechanics, reference depth and the reasoning live in /docs, and shared one-liners come from glossary modules (e.g. `EmisarWeb.RunStatuses`) so the two surfaces cannot drift.
- **Content:** [public claims follow owned contracts](.agent/kb/rules/content-public-claims-follow-owned-contracts.md) — derive public counts, plan features, and required certification lanes from their owning implementation; name related security evidence layers separately and state only what each one proves.
- **Content:** [public docs state required actions, not private implementation](.agent/kb/rules/content-public-docs-state-required-actions.md) — tell the reader which customer-facing action or contract applies; omit backing providers, internal topology, and unsolicited statements about work they do not need to perform.
- **Content:** [an email paragraph is one line](.agent/kb/rules/content-emails-keep-a-paragraph-on-one-line.md) — a plain-text body carries newlines for structure only (blank line between blocks, code/URL alone, two-space `Label:` blocks); a mail client re-wraps a long line but can never undo the newline we sent, and a source wrap around an interpolated name breaks at a column the reader never sees.
- **Infra:** [optional-resource refs use splat, never a hard index](.agent/kb/rules/infra-optional-resource-splat-refs.md) — a consumer that can outlive a count-gated resource references it as `A[*].attr` so absence degrades to `[]`; `A[0].attr` bakes in existence and turns a lifecycle flip into graph surgery.
- **Infra:** [trusted colocated administration reuses release RPC](.agent/kb/rules/infra-colocated-admin-release-rpc.md) — a private pack uses existing runner argv and one fixed `bin/emisar rpc` boundary; never change the client runner or add another transport for one internal pack.
- **Infra:** [transient scarcity is not bought off with standing spend](.agent/kb/rules/infra-no-standing-spend-for-transient-scarcity.md) — an occasional stockout, quota burst, or cold start is answered with a free mechanism or an accepted delay; never with a reserved slot, warm spare, or larger tier that idles between the rare events it exists for.
- **Packs:** [fixtures assume an isolated, non-root SUT](.agent/kb/rules/packs-fixtures-match-the-isolated-nonroot-sut.md) — never assert a bridge-assigned address, arrange the state the case reads, and declare `runner_user: root` where the command is superuser-reserved; Docker Desktop masks both ownership and AppArmor, so only the Linux matrix can judge this class.
- **Packs:** [no privileges from a setuid or setgid helper](.agent/kb/rules/packs-no-setuid-helper-elevation.md) — the runner sets `no_new_privs` on every action child, so a setgid helper like `postqueue` never elevates; the action states the access it needs and its behavior case runs as an identity that really has it.
- **Packs:** [suggestions use explicit evidence](.agent/kb/rules/packs-suggestions-use-explicit-evidence.md) — runtime dependencies never become host-discovery signals; a pack without authored `detect` evidence is not guessed.
- **Packs:** [HTTP API actions fail on response errors](.agent/kb/rules/packs-http-actions-fail-on-response-errors.md) — every curl-backed API action uses `-f`/`--fail` or explicitly accepts and reports arbitrary status; transport success alone never turns a 4xx/5xx response into a successful run.
- **Packs:** [response-supplied URLs reach curl with globbing off](.agent/kb/rules/packs-response-supplied-urls-disable-curl-globbing.md) — a URL that arrives in an API response is fetched with `--globoff` and a confined `--proto`, and a credential-bearing URL enters through a stdin config document, never argv; curl otherwise expands `{a,b}` into one transfer per alternative and hands a presigned signature to a host the response chose.
- **Packs:** [shell pipelines fail on source errors](.agent/kb/rules/packs-pipelines-fail-on-source-errors.md) — guard the input before piping into `tail`/`head`, so a missing log fails instead of reporting the empty output as "no errors"; never reach for `set -o pipefail`, which turns `grep`'s legitimate no-match into a false alarm.
- **Packs:** [jq filters stay on core jq](.agent/kb/rules/packs-jq-filters-stay-on-core-jq.md) — the regex family (`test`/`match`/`gsub`/`sub`/`capture`/`scan`/`splits`) exists only when jq was linked against Oniguruma, so a projection calling one fails on a minimal host *after* the command already ran; spell character classes and shape checks with `explode`/`split/1`/`ascii_downcase`, and prove the rewrite with a differential against the old spelling.
- **Packs:** [structured output fits the 8 KiB cap at its advertised worst case](.agent/kb/rules/packs-structured-output-fits-the-cap.md) — bound every free-text field and list-page argument so the worst advertised page fits the runner's structured-output cap after JSON escaping, declare the bounds in the schema, and prove it with a behavior case at the maximum size — the runner enforces the cap, so the case's success is the byte assertion.
- **Packs:** [redaction completeness follows a closed key space](.agent/kb/rules/packs-redaction-completeness-follows-a-closed-key-space.md) — tier a secret-bearing read on its redaction only when the VENDOR owns the key space, so every secret-bearing key is enumerable (`redis.config_get` → medium); operator-authored free-form config (`nginx -T`, Caddyfile, cloud-init, crontab, env dumps) has an open key space and stays high. Generic log readers are never above medium — arbitrary content, best-effort redaction, accepted by decision.
- **Packs:** [model-visible output keys avoid the secret vocabulary](.agent/kb/rules/packs-output-keys-avoid-secret-vocabulary.md) — the runner's default redaction rewrites any string under a `token`/`secret`/`key`-compound-named JSON key to `[REDACTED]` with no value check, so a pagination continuation projected as `next_page_token` never reaches the model; name it `next_page_cursor`/`page_cursor`, and prove any secret-named key that must exist with a behavior case asserting a real value round-trips unredacted.
- **Packs:** [remote packs need fixture and live read evidence](.agent/kb/rules/packs-remote-actions-need-fixture-and-live-read-evidence.md) — model every new remote action through its real client, then run a governed read-only provider smoke before claiming live compatibility; fixture success is never presented as production proof.
- **Runner:** [host readiness stays separate from descriptors](.agent/kb/rules/runner-host-readiness-separate-from-descriptors.md) — preserve complete trusted-manifest comparison and report mutable host readiness as subtractive deployment evidence.
- **Runner:** [host identity follows the hostname](.agent/kb/rules/runner-host-identity-follows-hostname.md) — default external identity to the current hostname so a replacement host naturally enrolls as a new runner; never mint or persist a parallel generated identity.
- **Shared:** [public customer skills stay portable and contract-accurate](.agent/kb/rules/shared-public-customer-skills.md) — publish customer workflows under `skills/` using only public interfaces, canonical MCP names and values, and returned continuations; audit cited tool names against the normative schema.
- **Shared:** [solve the owned problem, not the general one](.agent/kb/rules/shared-solve-the-owned-problem.md) — first-party inputs get authoring-time lints, never runtime exactness subsystems; pre-1.0 single-release deployments get no rollout barriers, dual formats, or never-shipped-peer handshakes; a new validation choke point deletes the checks it shadows in the same change.
- **Shared:** [write control bytes with printf](.agent/kb/rules/shared-write-control-bytes-with-printf.md) — produce ESC/NUL with `printf` and verify with `od -c`; a raw byte pasted into an edit or heredoc is silently dropped or mangled.
- **Shared:** [Docker inputs enter at their narrowest layer](.agent/kb/rules/shared-docker-inputs-enter-at-narrowest-layer.md) — introduce each copy, build argument, and environment variable immediately before its first real consumer so unrelated edits preserve dependency, application, and runtime layer caches; reuse the filtered root context for first-party images and keep `.dockerignore` with its context unless a narrower boundary has a concrete benefit.
- **Shared:** [repository knowledge lives in the KB](.agent/kb/rules/shared-repository-knowledge-lives-in-kb.md) — the website owns product documentation; repository cards, specifications, runbooks, and rules live under `.agent/kb/`, while published integration files use explicit tracked subtrees under `dist/`.
- **Shared:** [external integration files need explicit proof before deletion](.agent/kb/rules/shared-external-integration-files-need-explicit-proof.md) — no in-repo references does not make externally sourced or discovered files stale; confirm their external consumers before deletion.
- **Shared:** [human development tooling is not agent state](.agent/kb/rules/shared-human-dev-tooling-is-not-agent-state.md) — expose shared commands through `./run`, keep reusable implementations under `tools/`, share one application dependency topology, colocate integration SUTs with their owning tests, feed primary SUT versions through one matrix input, keep disposable screenshots with their task, give generators owned output subtrees, and keep `.agent/` as configuration/state rather than another command surface.
- **Shared:** [durable knowledge has an explicit audience](.agent/kb/rules/shared-knowledge-audience-boundary.md) — keep the tracked KB customer-safe/public, put local non-customer-facing working material under gitignored `kb/internal/`, and review it for the exact destination before publishing an approved result elsewhere.
- **Shared:** [development TLS trust stays workspace-scoped](.agent/kb/rules/shared-development-tls-trust-stays-workspace-scoped.md) — mutate trust by exact workspace CA fingerprint and scope automated browser exceptions to the current leaf SPKI; never disable TLS validation globally.
- **Shared:** [browser security exceptions stay response-local](.agent/kb/rules/shared-browser-security-exceptions-stay-response-local.md) — external integration compatibility relaxations happen only after request validation, on the exact response that needs them, with fixed application-controlled targets.
- **Shared:** [model catalogs expose only trusted pack refs](.agent/kb/rules/shared-model-catalog-trusted-only.md) — filter non-trusted exact pack refs before deriving any model-visible action, runner, runbook, issue, or continuation; mutations still recheck trust transactionally.
- **Shared:** [reversible and terminal runner states stay distinct](.agent/kb/rules/shared-runner-lifecycle-states.md) — disable keeps the identity retryable so enable recovers without host access; delete/revoke is terminal and never inherits retry behavior.
- **Shared:** [a capture rig owns what it creates](.agent/kb/rules/shared-capture-rigs-own-what-they-create.md) — a tool that creates an app, client, project or user in someone's tenant must be able to list and remove it, and must never report a tenant clean from a filter that could fail to match.
- **Shared:** [CI decides what a workstation cannot](.agent/kb/rules/shared-ci-decides-what-a-workstation-cannot.md) — pack fixtures, workflows, and the behavior harness hide uid ownership, AppArmor, startup races, and registry limits from a workstation, so treat a local pass as iteration feedback and expect the Linux matrix to be the judge of that class.
- **Shared:** [every blocking check lives inside the canonical gate](.agent/kb/rules/shared-checks-live-in-the-canonical-gate.md) — CI reaches a check by invoking `./run gate`, never by running the tool in its own step; a CI-only check makes a green gate a false promise and hides findings until someone pushes.

When the user corrects something — a naming call, a "use X not Y," a structural nit — it is a **rule**, not a one-off fix. In the **same change**:

1. **Fix** the flagged instance.
2. **Record** the rule **as a general shape — the pattern to recognize plus the fix — never a description of the one function you just fixed.** A rule pinned to a single function (`fetch_and_lock_account does X`) teaches nothing transferable and can't drive step 3; the same rule stated generally (*single-row reads return their tuple via `Repo.fetch`, never `Repo.one` + a hand-rolled nil-check*) both stops you writing it again anywhere and names exactly what to grep for. State the abuse case, give a sweep target. A one-line entry in the project `AGENTS.md` rule index, plus — when it needs worked examples — a domain-prefixed `kb/rules/<domain>-<slug>.md` file (*rule · why · ✅ good · ❌ bad · how it's enforced*).
3. **Sweep** the codebase for other instances of the old shape and fix them too — the generally-stated rule from step 2 is what makes this a mechanical pass rather than a guess.
4. **Graduate** it: if the rule is mechanically checkable, add an automated check so it can't regress — portal → an `Emisar.Checks.*` Credo check (wired into `.credo.exs`, fixture-verified to fire); Go → `go vet` / a linter / a hook.

A correction that only fixes the flagged line *will* be repeated. This pipeline exists to prevent exactly that. Rule filenames are namespaced for discovery: `design-*` for visual/UX rules, `content-*` for writing/content rules, `elixir-*` for portal Elixir conventions, and `runner-*`, `mcp-*`, `packs-*`, `infra-*`, or `shared-*` for those domains. Never add a new bare rule filename.

---

## One setup, two tools (Claude + Codex)

**Governing principle:** all durable knowledge and state live in tool-neutral files at fixed paths — `AGENTS.md` and `.agent/`. Each tool's native config is a **thin wrapper that points into those files, never a copy.**

- **Instructions** — `AGENTS.md` is canonical. Codex reads it natively; Claude reads it through the `CLAUDE.md` symlink at each level (root + every project).
- **State + knowledge** — `.agent/` is read and written identically by both tools.
- **Contributor skills / commands** — one source: `.claude/skills/`. Claude reads it natively; Codex reads the **same files** via the `.codex/skills` → `../.claude/skills` symlink (Codex auto-discovers a project-level `.codex/skills/` and ignores Claude's extra frontmatter). No per-tool skill copies.
- **Customer skills** — public product artifacts live under `skills/<name>/`, use portable frontmatter and public interfaces, and never depend on a repository checkout, `AGENTS.md`, `.agent/`, internal contributor skills, or `.claude/` / `.codex/` discovery. `skills/README.md` owns direct customer installation.
- **Enforcement** — Claude hooks under `.claude/` (Stop, commit-gate) and git hooks under `.githooks/` (`pre-commit` runs the staged check; `commit-msg` verifies that a `Coop-Task:` line git would silently drop is caught, since a line that reads as bound and is not is worse than none); reusable *logic* lives under `tools/` and enters through `./run` so CI or another tool can call it. This layer is genuinely per-tool (Codex has no hook equivalent) — never duplicate *knowledge* into it.
- **Bookkeeping audit** — after changing `AGENTS.md`, `.claude/skills/`, `skills/`, `.codex/`, hooks, or task-queue conventions, run `./run check agent-setup`. It checks the cross-tool symlinks, current `coop` verbs/state names, and contributor/customer skill metadata so stale agent instructions fail fast; `./run gate tooling` and CI run it too.

---

## Skills & hats

Two kinds:

- **Generic hats** — `/product-manager`, `/design-ux`, `/security-engineer`, `/content-seo`, `/workflow-spec`, `/workflow-work` — apply repo-wide regardless of language. Wear one when a change leans hard on its domain.
- **Per-product engineering skills** — language-specific. The Elixir set (`/elixir-context-fn`, `/elixir-new-context`, `/elixir-iron-review`, `/elixir-recurrent-jobs`, `/elixir-performance`, `/elixir-testing`, …) is **portal-only**. Go work in `runner/`/`mcp/` uses the Go engineering skill plus that project's `AGENTS.md`.

For a thorough pre-merge review, **`/review-board`** convenes the relevant hats above as parallel review subagents and synthesizes one ranked verdict + a prioritized fix plan. Use `/review-ship` for a lighter proportional review; the fix plan can be queued straight into `.agent/tasks/00_todo/` for `/workflow-sweep`.

Contributor skills are thin entry points — the durable rules they apply live in `AGENTS.md` and `.agent/kb/rules/`. Both tools share those internal skill files: Claude via `.claude/skills/`, Codex via the `.codex/skills` → `../.claude/skills` symlink (auto-discovered when Codex runs in the repo). Customer-distributed skills are a separate public product surface under `skills/`; see `skills/README.md`.

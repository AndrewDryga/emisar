<!-- roles/lead.md — guidance for the LEAD, appended to (never replacing) coop's
     generated contract. This copy is tuned for the emisar monorepo; the creed,
     the five-project map, and the per-project gates live in AGENTS.md (root +
     the project you're editing), which you have already read — don't restate
     them, live them. -->

## Route before you write

Before touching code, classify the change: JUDGMENT (design, tricky logic, anything
touching a trust boundary) or MECHANICAL (you could specify it exactly in a few
sentences). Route it, and keep your own context for synthesis and the final call —
if you catch yourself grinding out repetitive edits by hand, stop and hand them off.

First, recall before you re-derive: scan `.agent/kb/README.md`'s index and the
touched project's indexed `.agent/kb/rules/` before you start — open a descriptive
card only when it matches the subsystem you're editing. A minute here beats re-learning a trap the
hard way. And read the PROJECT's own `AGENTS.md` (portal/runner/mcp/packs/infra)
before editing inside it — each has non-negotiable, per-language rules.

- **thinker** — architecture calls, intermittent bugs, and a pre-commit review of
  anything on a trust boundary. NOT every task: a mechanical rename, a doc/description
  sweep, or a diff fully judged by the gate ships on the gate plus your own review —
  measured, a reflexive consult added 3+ minutes and millions of tokens to every task
  while changing nothing outside trust boundaries. When you skip one, say so in log.md
  in one line. Trust boundaries remain: surfaces that ingest runner / LLM / operator input,
  policy + approval gating, pack schema validation, the runner↔portal and MCP wire
  paths. It returns a conclusion with file:line evidence; you act on it.
- **critic** — one self-contained question when a decision is one-way or
  security-shaped: a committed DB migration (FROZEN once merged), a wire/protocol
  format, pack manifest semantics, billing/entitlements. State the plan, the
  constraints, and ask what breaks. Another vendor's blind spots are not yours —
  when you overrule it, say why in the task log.
- **fast** — the default implementer, and a cheap fast model by design: you are the
  expensive tier, so you think, review and steer while it types. Once YOU have decided
  the approach, write the spec (files to touch, the exact behavior, the acceptance
  checks) and hand the code-writing over.

  **The bright line:** before you write the THIRD file of a change, or any block of
  mechanical code longer than about fifty lines, stop and delegate the rest. Keep for
  yourself only what delegation would make worse: the investigation that produces the
  spec, a fix whose spec IS the diff (a few lines), and work where mid-edit judgment is
  the actual task (a live incident, an API you are still probing). If you implement a
  qualifying change yourself anyway, write one line in the task's `log.md` saying why —
  an unexplained solo implementation is the failure this rule exists to catch.

  **Budget its latency.** A delegate that has produced nothing after ~5 minutes is not
  coming back usefully: interrupt it, note it in `log.md`, and implement the slice
  yourself. Do not sit in the foreground waiting — that spends the expensive tier's time
  to save the cheap one's.

  Review its handback like a stranger's PR; it never commits — you run the touched
  project's gate and you commit. If its diff is off-spec, tighten the spec and
  re-delegate once; past that, take it over and note why in the task log.

## Consult like a research lead

- **Don't anchor your advisors.** On an open or high-stakes question, hand thinker
  and critic the neutral problem statement and constraints — not your favored answer.
  Two advisors anchored to your leaning are one opinion; share your own candidate only
  in a second round, after each has committed to its own.
- **Reviews carry a trap list.** "Review this" finds what's easy; a named trap finds
  what's expensive. When routing a review, enumerate the specific failure modes to
  hunt — e.g. validation skipped on a retry path, an approval check bypassed by a
  second entry point, a pack field interpolated into a shell string, a migration
  edited instead of added — not just the files to read.
- **One wave is not a consult.** When answers come back conflicting or with a gap,
  that's the input to round two — re-ask with the contradiction or counterexample the
  first round exposed — not a coin flip between them.

Verify what comes back. A role's answer is an input, not a verdict: reproduce the
bug it diagnosed, run the test it claims passes, spot-check the sweep it says is
complete. You own the result; "the subagent said so" is never a reason in a commit.

## Scope is part of correctness

The task's named scope is a hard boundary, not a suggestion. If the fix you're
building grows past what the task names — a new dependency, a new on-disk format,
a rewrite of the function you were asked to test — STOP: finish the named slice,
and queue the growth as its own task (`coop tasks add`) or backlog item
(`coop backlog add`). A finished small task beats a sprawling perfect one.

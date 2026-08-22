# Plain, specific prose beats corporate abstraction

## Rule

Write public, product, documentation, and editorial content for one known reader
using ordinary words, concrete mechanisms, and an honest point of view. Every
sentence must state a useful fact, explain a mechanism or consequence, provide
proof or an example, answer an objection, guide an action, or add relevant
personality. Cut it when it does none of these.

Keep technical precision, but do not use complexity to signal expertise. Adapt
the writing to its surface: persuasive and proof-led on marketing pages, terse
and state-specific in product UI, task-first in docs, thesis-led in blog posts,
and change-first in release notes. Do not reuse one generic SaaS cadence across
them.

## Why

Corporate abstractions and marketing filler make readers work harder while
hiding the claim they need to evaluate. Formulaic transitions, symmetrical
lists, inflated adjectives, and polished paragraphs without testable meaning
also make the copy feel generated because they replace judgment with a template.

Clear prose is not simplistic prose. It lets a skeptical reader understand the
product, challenge the claim, and decide what to do next without decoding the
writer first.

## Good

- Lead with the reader's actual job, question, or decision.
- Put the product mechanism or evidence next to the benefit it supports.
- Explain a fact once, in the order the reader needs it. Do not follow an
  abstract summary with a paraphrase of the same behavior.
- Use active verbs and the ordinary word when it is equally precise.
- Call a standard operation by its standard name — a key is *exchanged* for a
  token (the industry's own term), never "traded". A coined verb reads cute
  once and costs a search hit forever.
- Name a console state with the console's own component — a run status, pack
  trust state, runner online state, or compat verdict quoted in docs renders
  through the same `status_badge`/`chip`/`docs_risk` the console uses, so the
  reader sees exactly what the surface will show and the two cannot drift.
  Mirror only what the console really renders: an `unsupported` rose chip is
  faithful, an `outdated` chip is not (the console shows a quiet glyph).
- Set a literal identifier — a YAML key, flag, env name, field — in code
  (`kind`, `--hash`, `setup.verify`). Bold is for emphasis words, status
  labels, and UI control names, never for identifiers.
- Say `test it` or `make sure it works` for a step that checks something.
  `Prove` belongs where evidence itself is the subject — an audit record, a
  signature, a hash chain — never as the verb for an ordinary verification
  step.
- Vary rhythm with the idea, not through arbitrary fragments or decoration.
- Use humor only when it sharpens the point and preserves trust.
- State a verified fact directly and qualify the exact uncertainty.
- Frame normal resilience as the capability — `The runner reconnects on its
  own` — never as tolerance of a failure class (`Disconnects are expected`).
  Any product handles its ordinary events; say what it does.
- Send a reader to another page by naming what they want to do — `To upgrade
  runners instead, see Upgrade runners` — not by stating a fact about how the
  system is arranged.

## Bad

- Praise the product without naming what it does.
- Let internal shorthand reach an operator — "pack bytes", "puts bytes on a
  host", "the bytes are" come from the trust model's content-addressing; the
  reader knows them as the pack, its version, or its files. "Bytes" survives
  only in genuinely byte-level facts (byte-for-byte, a hash over the files).
- Open with `In today's fast-paced landscape` or another empty scene-setter.
- Repeat `not just X, but Y`, forced triads, rhetorical reveals, or identical
  paragraph shapes until the structure becomes visible.
- Turn ordinary behavior into a punchy metaphor just to make the sentence sound
  quotable. If the image adds no precision, state what the system does. This
  bans even the GOOD line: "A request nobody answers is an outage with a polite
  name" survived two editing passes because it read well — docs still replace
  it with what happens and what to do about it.
- Tail a statement with its mirrored negation — `refused, not followed`,
  `expected; a blocked path is not`, `housekeeping, not a security control`.
  Say what happens and stop. Keep a negation only when it corrects an
  expectation the reader really brings (`the node, not the pod, is the
  identity`), and prefer giving that correction its own plain sentence.
- Prompt an action with a tool fact. `emisar doctor checks reachability.` states
  trivia; the sentence exists to make the reader run the command, so address
  them: `Use emisar doctor to check that the control plane is reachable.` The
  fact form is right only when describing behavior the reader is not being
  asked to invoke.
- Dress a plain action in an ownership idiom — `is yours to edit`, `yours to
  kill` — when the literal statement (`you can edit it`, `you can still revoke
  it`) is shorter and says exactly what to do.
- Describe an option by its implementation metaphor — `freezes that runner`,
  `expands the group to one logical item per online member` — instead of what
  it does for the reader: `runs the step on that runner`, `runs the step on
  every online runner in the group`. Internal semantics (freezing, expansion,
  logical items) stay in the paragraph that explains the mechanism, if they
  are needed at all.
- Quantify over customers — `revoke it in each account` reads from the
  vendor's chair. The docs reader runs one account, so name the surface they
  open (`revoke it in Packs`); phrasing that ranges over accounts belongs only
  where the reader genuinely has several (the CLI's multi-account switching).
- Repair an overclaim by appending its refutation. Cutting `Air-gap friendly`
  does not earn `emisar does not run air-gapped` in its place — the boundary
  fact belongs to its owner page, and after any correction every sentence the
  edit touched must re-earn its place for THIS page's reader. The default
  repair is deletion.
- Patch a much-edited passage one clause at a time. When a paragraph has been
  revised repeatedly, count the facts it must carry and rewrite it as roughly
  one sentence per fact — if the information is four sentences, the paragraph
  is four sentences. The tell: transition sentences that only stitch earlier
  edits together, and the same noun re-qualified in each clause.
- Chop one connected thought into uniform clipped sentences, controlled-language
  style — `Trust is bound to the hash. A runner with the trusted hash does not
  need a second decision. A different hash is drift. Drift stops the rollout.`
  loses the reasoning even though every sentence is simple. Split a sentence
  when it carries more than one idea; keep the connector that names how the
  ideas relate (a colon, `so`, `and`, `when`, a dash): `Trust is bound to the
  hash: another runner with the trusted hash does not need a second decision,
  and a different hash is drift — it stops and asks for review.` Short is a
  budget, not a style; the flow of thought outranks the word count.
- Fold a negation into a pronoun or noun object — `changes nothing`, `writes
  nothing`, `needs none`, `carries nothing secret`, a bare `No restart` — where
  the spoken form negates the verb: `does not change anything`, `does not need
  one`, `the runner does not restart`. Better still, name what stays unchanged
  (`does not change what runs`). The existential `There is no rollback command`
  is already the plain form and stays.
- Open a bullet with a bolded slogan-title that restates or teases the fact
  its sentence then gives — `An empty page is an answer.`, `Two headers, two
  different jobs.`, `Start once, then always resume.` (2026-08-23). Give the
  facts directly and bold the load-bearing phrase inside the sentence
  (`continue with the cursor you already had`), so the skimmer's eye lands on
  the instruction, not on a headline. A bolded opener or title is fine when it
  IS the fact or instruction itself (`Keep the filters identical for the life
  of a cursor`) — the defect is the teaser, not the position. Bold anywhere
  (bullets and paragraphs alike) is a best-judgment emphasis for the few
  phrases a skimmer must not miss, never a mechanical pattern: adding it to
  every paragraph's imperative is abuse, and both over-use and a blanket ban
  were corrected the same day (2026-08-23).
- Pad a walkthrough with reference material. After the connect example, the
  CLI-agent page stacked flag semantics, update policy, and transport trivia —
  five paragraphs the founder cut to one (2026-08-22). A task page carries the
  minimum that finishes the task plus ONE link to the reference page that owns
  the surface; enumerate the flags there. When the reference does not cover
  them yet, move the material there in the same change — never leave the link
  pointing at a page that cannot answer it.
- Give a feature the verb `proves` — `Test connection proves discovery`, `A
  listed tool proves metadata access` (2026-08-23). A diagnostic *checks* or
  *tests*; a listing *means* or *shows*; only a person proves something, by
  doing it ("prove the whole path once: run one low-risk action" stays). The
  overclaim is the defect: "proves" promises more than the feature examined.
- Append the reason as an em-dash punchline — `it cannot sign a new claim — it
  holds neither private key`. A cause is a connected clause with its everyday
  connector, not a verdict fragment the reader must unpack: `it cannot sign a
  new claim, since it does not hold a private key`. The `neither X` compression
  is part of the same tic — spell the plain singular. An em-dash still earns
  its place when what follows is a full connected thought (`— it does not
  decode and rebuild them, so escapes stay exact`), not a clipped noun phrase.
- Compress what the reader would see into an insider verb — an artifact that
  "names" its contents, a run that could "reinterpret an argument", a CLI unsure
  about "server receipt of a mutation", a plan read "as the dispatch receipt".
  Say what actually happens with the everyday verb — and for an artifact the
  reader looks at (a log, plan, error, response, section, table row), that verb
  is *shows*: the plan *shows which runner it picked*, the log *shows what
  failed*, the error *shows the cause*. `Says` and `tells you` personify the
  artifact and were corrected to `shows` on sight. Elsewhere pick the verb for
  the mechanism: the audit event *records*, the CLI *prints*, arguments are
  *used exactly as you entered them*, the CLI *cannot be sure whether the
  server received it*, and the compatibility ban is on *changing a frozen
  value's meaning*, not "reinterpreting" it. Noun uses stay (`the env names
  the tool reads`, the installer's root-owned receipt file). Sweep: ` names
  the`, ` names both`, `reinterpret`, ` receipt of `, ` says what`,
  ` says which`, ` tells you ` in `marketing_html/`.
- Spell out the override mechanism when stating a default — `5 unless the
  definition sets another value` restates what "default" already means. Say
  `5 by default`; where the value is set is the surrounding section's subject.
  Sweep: `unless the .* sets` in `marketing_html/`.
- Tell the reader to "escalate" — or its equally orphaned replacement,
  "report it" — when the sentence has no recipient. The customer has no tier
  to raise anything to, and "report it" leaves them asking to whom and how.
  Name the action WITH its destination: *contact support* (the page's closing
  sections then carry the evidence list and the address). "Escalate/escalation"
  stays only for things that genuinely climb — privilege escalation, or a
  customer's own on-call process. Sweep: `[Ee]scalat` and bare `[Rr]eport it`
  lead-ins in `marketing_html/`.
- Give advice that dies at "and then what?" — `look before you mint another`
  points the reader at a successor row whose secret is shown once and can never
  be viewed again, so nothing they find changes their next move. Every
  troubleshooting instruction must end in an action the reader can take with
  what it shows; when the honest answer is "the fix is always X", say that
  (*rotating or minting is the fix, never a lookup*).
- Stamp a delete or revoke with the verdict adjective — `Deleting is
  terminal`, `Revocation is terminal`, `a revoked one is terminal`. Say what
  the reader loses: *a deleted runner cannot be restored*, *revocation cannot
  be undone* — and what happens next (the host enrolls again as a new runner).
  The run-lifecycle sense on reference pages (`a terminal result`, `terminal
  status`) is defined domain vocabulary and stays. Sweep: `is terminal`,
  `— terminal` in `marketing_html/` and console templates.
- Serialize independent caps into a paragraph — eleven `at most` sentences in a
  row is a list wearing prose and cannot be scanned. Independent numeric facts
  render as a table in the house `What | Limit` shape (or a short bullet list),
  one row per fact; prose is for connected thought. Sweep: docs paragraphs with
  4+ `at most`/`up to` sentences.
- Interleave several tools' behaviors in one paragraph — a spec dump the reader
  must untangle. Group by the reader's job, one paragraph each (read, edit,
  run), and state each tool's rule where that job is discussed.
- Contrast two workflows by giving each a "place" when they share the
  mechanism — `keep open-ended diagnosis in the action catalog` reads as if
  runbooks bypass the catalog, but both draw from it. Name the real behavioral
  difference: a runbook runs a frozen, known plan and cannot change it mid-run;
  diagnosis dispatches one action at a time and reacts to each result.
- Add typos, slang, fake anecdotes, or random sentence variation to "sound
  human."
- Make docs sell, make UI errors joke, or make marketing copy read like a manual.
- Justify a cross-link with our own topology (`Runner releases move separately`,
  `The workstation bridge moves separately`). The reader did not ask how release
  lines are organized; they asked which page upgrades their runner.

## Enforcement

Use the contributor `content-director` skill for writing and review. On every
changed surface, run the spoken, competitor-swap, proof, and deletion tests in
that skill. Sweep nearby marketing copy, product microcopy, docs, and editorial
content for the same rejected pattern when a human correction reveals one.

This rule depends on editorial judgment, so most of it is enforced through
review and examples rather than a banned-word grep — but every EXACT phrase the
founder corrects graduates the same day into
`EmisarWeb.ContentTicsTest` (portal), a tripwire over the marketing templates
that fails the suite if a corrected tic ever reappears. Judgment stays here;
the ledger of exact corrected phrases lives in that test, one entry per
correction, fixture-verified against the sentence that earned it. When a
correction lands, add the phrase there IN THE SAME CHANGE if it greps with
zero false positives on the current site (legal pages excluded — a contract
legitimately says "the responsibility is yours"). Technical uses of words such as
`scalable` or `robust` remain valid when the content states the tested scale or
the failure the system withstands.

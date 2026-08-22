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

This rule depends on editorial judgment, so enforce it through review and
examples rather than a banned-word grep. Technical uses of words such as
`scalable` or `robust` remain valid when the content states the tested scale or
the failure the system withstands.

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
- Use active verbs and the ordinary word when it is equally precise.
- Vary rhythm with the idea, not through arbitrary fragments or decoration.
- Use humor only when it sharpens the point and preserves trust.
- State a verified fact directly and qualify the exact uncertainty.

## Bad

- Praise the product without naming what it does.
- Open with `In today's fast-paced landscape` or another empty scene-setter.
- Repeat `not just X, but Y`, forced triads, rhetorical reveals, or identical
  paragraph shapes until the structure becomes visible.
- Add typos, slang, fake anecdotes, or random sentence variation to "sound
  human."
- Make docs sell, make UI errors joke, or make marketing copy read like a manual.

## Enforcement

Use the contributor `content-director` skill for writing and review. On every
changed surface, run the spoken, competitor-swap, proof, and deletion tests in
that skill. Sweep nearby marketing copy, product microcopy, docs, and editorial
content for the same rejected pattern when a human correction reveals one.

This rule depends on editorial judgment, so enforce it through review and
examples rather than a banned-word grep. Technical uses of words such as
`scalable` or `robust` remain valid when the content states the tested scale or
the failure the system withstands.

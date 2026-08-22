# Say it once — don't re-explain the same idea

## Rule

State each idea in its clearest place, once. Every paragraph, list item, callout,
and sentence after it must add something new — a concrete example, a caveat, a
limit, a next step, a link — not restate the idea in fresh words. If a passage
only recaps what the reader just read, cut it.

The failure this targets is redundancy that masquerades as emphasis: a labelled
"summary" paragraph that recaps the list above it, a value prop repeated in the
step body and again in the closing callout, a memorable slogan that re-explains
the mechanism just described, the same point made three ways in three sentences.

Simple writing means the reader gets it on the first read — not that you force it
in by repetition. Trust the first, clearest statement; repeating it signals you
don't, and it bloats the page.

## Why

Repetition doesn't reinforce a point for a competent reader — it wastes their
time and reads as filler. It also makes the writing feel generated, because
saying the same thing several ways is what you do when you're padding, not when
you have something new to add. Every restatement is a sentence that failed the
"does this add anything?" test in `content-plain-specific-prose.md`.

## Good

- Numbered list gives the three steps; the next paragraph adds a *concrete
  example* ("See it on a real incident: the 33-hour wipe → …") and nothing else.
- A concept is explained in the one section that owns it; other pages *link* to
  it instead of re-explaining it.
- A quickstart step says what to do and what you get, then links to the full
  walkthrough — it doesn't recap the whole value prop the closing callout carries.

## Bad

- A list of steps, then an "Imperative containment, declarative cure" paragraph
  that restates the same steps, then a use-case link that restates them a third
  time. (Quickstart §6 — the correction that created this rule.)
- "Reads run under policy, risky calls stop for a human, the model never gets a
  shell — every call is audited" in a step body when the closing "What you just
  built" callout already says it.
- A section that opens by naming the problem, then a callout that re-names the
  same problem before getting to the fix.
- **Preamble that only announces what follows.** "emisar has four ordered roles
  and one specialist role, billing manager." above the roles table — the table
  IS the roles, and counting them first tells the reader nothing they won't read
  one line later. Same for "Use this example to shape your runner fleet:",
  "After setup, directory sync does the following:", "Two facts decide how you
  revoke:". Delete the sentence and let the content start.
- **A scope disclaimer at the top of a page, ruling out a confusion nobody has.**
  "Sign-in identifies the person. What they can do is controlled by their role
  and runner access — changing the sign-in method does not change either." on the
  Authentication page. A reader on that page came to set up sign-in; opening by
  telling them what sign-in is *not* spends their first paragraph on a question
  they did not ask. If the boundary genuinely trips people, it belongs where they
  hit it, not as a gate in front of the page.

## Sweep

When editing or reviewing a page, read consecutive paragraphs together and ask of
each: *what does this add that the one above didn't?* If the answer is "it says
the same thing more memorably," cut it or merge it. Watch especially for: a
slogan/label paragraph following a list; a value prop that appears in both a step
and the page's closing callout; and the same mechanism explained on two pages
instead of one owning it and the other linking.

The mirror sweep is the page's *first* sentence and every `<p>` sitting directly
above a table or list: read the paragraph, then read what follows it. If the
content below states the same thing in a form the reader can actually use — the
table, the list, the form — the paragraph is preamble, and a heading already told
them what section they are in. A lead-in earns its place only by carrying a fact
the content below cannot: a caveat, a version note, a consequence, a limit.

## Enforcement

Judgment rule — not mechanically checkable. Caught in content review and the
`content-*` skills; this file is the shared reference. Applies to all customer-
facing prose (marketing, docs, product UI, blog, release notes).

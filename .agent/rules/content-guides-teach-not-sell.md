# Guides teach; the chrome sells

**Rule.** A guide/editorial piece (`/guides/*`) argues its case with zero product
mentions in the body — no "that's what emisar's X does" drop mid-explanation, no
internal docs links standing in as proof. The product appears in at most ONE
designated place the reader can see coming (a labeled "where emisar fits"
section, or nothing at all), and the page chrome — nav plus the shared guide CTA
banner — carries the conversion.

A product explainer is the explicit exception: when the title names emisar and
the reader's job is to understand how emisar itself works, the body may name the
product throughout. The title must make that genre obvious before the reader
starts. Teach the mechanism, trust boundaries, tradeoffs, and honest limits;
do not turn each section into a feature pitch or add conversion links through
the argument. Case studies and compare pages are also different genres. This
rule's zero-mention bar is for vendor-neutral teaching pieces.

**Why.** Readers share teaching and caveat brochures. A product drop inside the
section that is winning the reader's trust flips the genre — adversarial-reader
panels flagged the identical moment independently ("the article's vocabulary
stopped being mine and became the vendor's"). A guide converts by being the best
thing published on its topic under our name, not by routing each section toward
a purchase.

**✅ Good** (mechanism, vendor-neutral):

> And redact secrets before they ever reach the model: scrub output on the
> server itself, before it goes anywhere. Redaction is rule-based, so it is
> exactly as strong as the rules someone declared.

**❌ Bad** (same section, genre flip):

> That's what emisar's per-action redaction rules are — each action declares
> what to strip, and the runner applies those rules before output leaves the
> machine. See the [security model].

**❌ Also bad — the stealth pitch.** Filing the name off doesn't fix it: "the
strongest versions of this pattern re-check everything on the host against the
host's own copy of the action's definition" is still our architecture diagram
narrated anonymously. The test isn't whether the word emisar appears — it's
whether the sentence exists to teach the reader's problem or to describe our
differentiator. If the article's argument survives the sentence's deletion, the
sentence was a pitch; delete it.

**How it's enforced.** Review: before shipping a vendor-neutral guide,
`grep -c emisar` on its template — the body count is 0, or every hit sits inside
the one designated section. The safe-access guide's "One MCP for all of
infrastructure" section is the sanctioned designated-place shape; the
prompt-injection guide is the zero-mentions shape. For a titled product
explainer, review every section for mechanism or limitation and reject feature
laundry lists or repeated calls to action. Cross-links to sibling guides are
editorial and fine; links into `/docs/*` or `/how-it-works` from a
vendor-neutral guide body are the smell.

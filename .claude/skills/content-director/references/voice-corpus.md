# Build And Use A Voice Corpus

Use a voice corpus when approved writing, founder speech, customer language, or
repeated editorial corrections are available. A corpus gives the model evidence
about the brand's choices. A list of adjectives does not.

## Choose Evidence

Start with 3 representative samples. Use 5 or more when enough approved work
exists:

- approved pieces the team would publish again
- founder interviews or transcripts that sound natural
- high-quality examples from each relevant surface
- customer interviews, support messages, and objections for audience language
- human edits that show what the original draft got wrong

Do not learn blindly from every existing page. Exclude stale positioning, SEO
filler, ghostwritten work the team dislikes, legal text, and samples from a
surface with a deliberately different tone.

Never invent a voice profile from demographic stereotypes. Mark assumptions as
assumptions until real evidence replaces them.

## Extract Patterns

Analyze repeated choices, not isolated quirks:

- point of view and degree of conviction
- recurring house positions and how the writer defends them
- relationship to the reader
- technical depth and what the writer assumes
- common sentence and paragraph shapes
- pace, emphasis, and use of fragments
- ordinary vocabulary and product-specific terms
- transitions, openings, and endings
- use of examples, comparisons, questions, and asides
- humor style and topics kept serious
- punctuation and formatting habits
- words, claims, and tones the writer avoids

Separate **voice constants** from **surface shifts**. A brand can stay direct and
warm while becoming terse in product UI, exact in docs, persuasive on the
website, and more reflective in a blog post.

## Record A Compact Profile

Keep the useful result short enough to apply while writing:

```text
Core voice: <3-5 specific traits with behavioral definitions>
Reader relationship: <how the writer addresses and respects the reader>
Point of view: <how directly the brand takes a position>
House positions: <claims the brand is willing and able to defend>
Rhythm: <typical cadence plus what breaks it>
Vocabulary: <preferred ordinary and domain-specific language>
Humor: <what kind, how often, and where never>
Surface shifts: <website, product, docs, blog>
Avoid: <observed failure modes and rejected language>
Anchors: <short excerpts or before/after edits that demonstrate the rules>
```

For emisar, keep the positioning layers distinct when choosing anchors. The
canonical order and claim boundaries live in
`.agent/kb/rules/content-position-bounded-autonomy.md`:

- outcome: an operator can leave an agent doing infrastructure work without
  supervising every step or granting open-ended shell authority
- mechanism: declared actions, policy, pack trust, and runner-side validation
- first value: prebuilt packs and host-aware suggestions
- extensibility: one fixed MCP tool surface with new capabilities added as packs
- supporting controls: conditional approvals, audit, and SIEM export

Reject anchors that make the approval queue the hero. Many products can request
approval; the emisar argument is that bounded agents can continue useful work.

Use short excerpts only as evidence. Do not reproduce a source's memorable
phrases or impersonate an individual. Apply the underlying choices to original
content.

## Keep Canonical Anchors

Keep 3 to 6 short, approved passages for each register the team uses. Include a
website passage, a task-first documentation opening, a thesis-led editorial
passage, and one place where humor worked. Pair at least one accepted human edit
with the draft it replaced; the difference often teaches more than adjectives.

Until those anchors exist, use the behavioral anchors in `tone-rules.md` as a
fallback. Do not treat the current website or model-written output as approved
voice merely because it is available.

## Approved editorial corrections

When drafting or revising, consult the closest approved pair for the surface
and decision, including local internal examples when available. Apply the
editorial choice in fresh wording and verify product claims for this piece.

<!-- Append published pairs here. For each entry record surface, original,
accepted revision, endorsement, and user rationale or labeled inference.
Capture, storage, and replacement follow the KB rule linked below. -->

Follow the [correction rule](../../../../.agent/kb/rules/content-plain-specific-prose.md#capture-approved-editorial-corrections)
when a user edits or endorses wording.

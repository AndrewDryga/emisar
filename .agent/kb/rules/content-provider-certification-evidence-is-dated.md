# Customer-facing test evidence is dated and positive

## Rule

A customer-facing guide with durable runtime evidence ends with one short,
positive sentence that names what was tested and when:

```text
Tested with nono 0.75.0 on macOS on September 7, 2026.
```

- State the product, version, platform when it matters, and test date.
- Do not append internal qualification language about what the test did not
  include. Keep the exact scope, omitted lanes, fixtures, and limitations in the
  task's validation evidence or the owning KB.
- Show either the dated test sentence or `Last reviewed <date>` in the shared
  docs colophon, never both. A page without durable runtime evidence uses the
  review date and makes no test claim.
- A test claim is allowed only when durable evidence records that verification.
  Editorial work, screenshot recapture, and assumption never advance its date.
- Any evidence claim on an overview repeats the guide's wording and date; a
  summary never claims a stronger level of verification.

This applies to sandbox, provider, and other integration guides. The sentence
is customer evidence, not a dump of the internal qualification report.

## Why

A buyer needs to know that the documented combination worked and how old that
proof is. Long caveats about the test harness make a working guide sound
uncertain, while a second review date repeats weaker provenance beside stronger
runtime evidence. Detailed limits still matter, but they belong in retained
engineering evidence rather than the customer-facing footer.

## Good

```heex
<.docs_layout
  current="connect-nono"
  updated="September 9, 2026"
  evidence="Tested with nono 0.75.0 on macOS on September 7, 2026."
>
```

The rendered footer contains only the `Tested with …` sentence.

## Bad

```text
The sandboxed MCP transport and an audited action were live-tested with nono;
a signed-in agent was not part of that test.

Last reviewed September 9, 2026
```

The first paragraph exposes internal qualification scope and the second repeats
weaker provenance.

## Enforcement

`portal/apps/emisar_web/test/emisar_web/agent_sandbox_guides_test.exs` pins each
sandbox guide's exact sentence and rejects negative test-scope disclaimers and
duplicate review provenance. `marketing_test.exs` pins provider evidence, and
`marketing_structural_test.exs` requires every docs page to render either review
or test provenance.

When a claim changes, sweep the owning guide, any overview that repeats it, and
the exact rendered-page assertion in the same change.

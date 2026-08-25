# Third-party walkthroughs show every screen, in its chosen state, with the target marked

**Rule.** A setup guide for a third-party console is a *walkthrough*: one numbered step per
screen the operator actually encounters, one screenshot per step, each captured **after** the
step's input is entered or its option selected, with the exact control outlined. A guide that
shows one screenshot of a multi-screen flow, or shows a form before it is filled, is not a
walkthrough — it is a screenshot with prose around it.

**Why.** The reader is in someone else's console, which we do not control and which they may
never have opened. Everything they need to find they must find by eye. An unmarked full-console
screenshot makes them hunt; a screenshot of an empty required field reads as "this is optional";
a flow missing its middle screens strands them exactly where they cannot ask us for help. Each
of these shipped at least once and each was caught by the founder, not by a test.

Marking the target is also the only defence against a **default you did not choose**. A wizard
that pre-selects an option will produce a working-looking result that is silently wrong — and
because you never clicked it, you have no memory of a decision to re-examine. Outlining the
control forces you to look at what is actually selected before the shot goes in the docs.

The crop and marker are part of the instruction, not decoration. Keep the complete right edge
of every relevant field, button, and table column. Paint the outline above the vendor controls
so an input cannot cover one of its edges. When the instruction names a labelled unit, outline
the whole unit — heading, input, and action — rather than the heading alone. When every element
in the shown card is relevant, omit the outline instead of turning the card into a nest of green
boxes.

## The three failures this rule exists to stop

| Symptom | What the reader concludes | Actual defect |
|---|---|---|
| One screenshot for a four-screen wizard | "That's the whole setup" | Screens 2–4 never captured |
| A required field shown empty | "I can skip this" | Shot fired before the driver typed |
| A full console screen, nothing marked | *hunts* | No `highlight()` call before the shot |

## ✅ Good

```go
// Fill BEFORE shooting: a frame showing an empty Display Label teaches nothing.
focusField(ctx, "label")
chromedp.Run(ctx, chromedp.KeyEvent("emisar"))
highlight(ctx, "Display Label")          // outline the target
screenshot(ctx, outDir, "jc-07-general-info")
```

```elixir
# One step, one screen, one screenshot — and the step names the trap.
<p class="font-semibold text-zinc-100">Enable SSO, and pick OIDC.</p>
# ... "It defaults to SAML, and emisar's connection is OIDC, so this is the one
#      click on the page that is easy to miss and hard to undo later."
<.docs_screenshot src="/images/docs/sso/jumpcloud-sso-options.webp" ... />
```

## ❌ Bad

```go
screenshot(ctx, outDir, "jc-07-general-info")   // shot fires first…
focusField(ctx, "label")                        // …then the field is filled
chromedp.Run(ctx, chromedp.KeyEvent("emisar"))  // the docs get the empty frame
```

```elixir
# Two navigation acts in one step ⇒ one of the two screens has no screenshot,
# and a captured image silently goes unreferenced.
<p class="font-semibold text-zinc-100">Start a custom application.</p>
# "go to Access → SSO Applications and press Add New Application. emisar is not
#  in the catalog, so scroll past the featured tiles and choose Custom Application"
```

## How it's enforced

Review, plus two mechanical habits in the capture drivers
(`tools/cmd/okta-capture`, `tools/cmd/jumpcloud-capture`):

- `highlight(label)` outlines the smallest element carrying the text;
  `highlightControl(section)` outlines the row around a checkbox/radio, which carry no text of
  their own; `highlightGroup(anchor, companion)` frames a complete labelled unit. Call the
  appropriate helper immediately before every `screenshot`, except when the whole shown card is
  the instruction.
- **Look at every final published image at the width the docs render it before wiring it in.**
  Not the filename, not the driver's log line, and not only the uncropped capture — the final
  pixels. Check all four edges, marker continuity, selected state, secrets and account chrome,
  and that the caption describes what is visible. An MFA prompt captioned "Client Credentials"
  and a frame scrolled past the field its caption described both passed a green run and shipped.

Related: [`shared-docker-inputs-enter-at-narrowest-layer.md`](shared-docker-inputs-enter-at-narrowest-layer.md)
is the same shape one layer down — put the thing where its consumer is, not where it was
convenient to write.

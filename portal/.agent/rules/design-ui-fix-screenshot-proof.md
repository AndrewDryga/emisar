# Rule: a user-requested UI fix ships with before/after screenshot proof

**Rule.** When the user reports a visual defect on a rendered surface — console
or marketing — the fix is a four-step loop, and the FIRST step happens before
any code is edited:

1. **Before-shot** — capture the reported state from the running `:4010` stack:

   ```sh
   node portal/.agent/scripts/shot.mjs <path> --label before --select '<css>'
   ```

   Writes `test-results/ui-fix/before-full.png` (full page) and
   `before-crop.png` (the element under fix). Anchor by `--select CSS`,
   `--heading "exact text"` (+ `--climb section` to take the enclosing
   container), or `--class-contains a,b` for Tailwind arbitrary classes.
2. **Fix** — the normal workflow (AGENTS.md, `design-system.md`, the gate).
3. **Rebuild** — from the repo root: `docker compose build portal &&
   docker compose up -d portal`, wait for healthy. The screenshots see only the
   :4010 stack; an unrebuilt stack re-shoots the OLD code and the "after"
   proves nothing.
4. **After-shot** — same command, same anchor, `--label after`. Then LOOK at
   both crops (Read the PNGs) — confirm the defect is actually gone and the
   full page shows nothing around it regressed — and hand the user the
   before/after file paths (crop + full page) with a one-line summary of what
   changed, for their review.

**Why.** "Fixed" for UI means fixed in rendered pixels, not in the diff —
done-means-verified. The before-shot pins down what was actually broken (and
that the fix addressed *that*); it is unrecoverable once the fix deploys, so it
is captured first. The after pair is the verification artifact: the user
reviews pixels, not prose.

✅ before-crop showing the clipped label → fix → rebuild → after-crop showing it
whole + after-full clean → both paths handed over in the final message.

❌ "fixed the padding, should look right now" with no screenshots; an
after-shot taken against a stale (unrebuilt) stack; a before-shot skipped
because the fix "was obvious"; reviewing only the crop and missing a regression
the full page would have shown.

**Scope + edges.**

- Responsive-sensitive fix → repeat both shots with `--width 390`.
- State that needs interaction (an open menu, hover tooltip, mid-flow wizard
  step) isn't reachable via `shot.mjs` flags — extend the script per
  `capture-docs-screenshots.mjs`'s click-through pattern or drive Chrome by
  hand; the before/after discipline still applies.
- Console paths log in as the seeded `demo` account; use `EMAIL=` to shoot the
  staged `acme`/`globex` data volumes.
- This rule is for *user-reported fixes on rendered surfaces*. Building a new
  page/feature follows the design skills' own verification (full-page
  desktop+mobile review); no before exists there.

**Enforced.** Process rule (review): a UI-fix report with no before/after pair
in the conversation is incomplete. Mechanics: `portal/.agent/scripts/shot.mjs`
(see the README in that directory).

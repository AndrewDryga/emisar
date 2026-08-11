# Rule: a user-requested UI fix ships with before/after screenshot proof

**Rule.** When the user reports a visual defect on a rendered surface — console
or marketing — the fix is a four-step loop, and the FIRST step happens before
any code is edited:

1. **Before-shot** — ensure the work has a claimed task, then capture the
   reported state from `./run serve`. A one-off visual review still gets a basic
   task: create it in the relevant queue with `coop tasks add --project portal
   "<title>"`, then `coop tasks claim <id>`. This ownership is intentional:
   clearing completed tasks clears their disposable screenshots too.

   ```sh
   ./run shot <path> --label before --select '<css>' \
     --group <what-is-fixed>
   ```

   `shot` selects the sole task under `10_in_progress/` and writes
   `screenshots/<group>/before-full.png` plus `before-crop.png` under that task.
   Pass `--task <id>` when several tasks are active. It does not accept an
   arbitrary output directory. Anchor by stable `data-shot` name with
   `--shot <name>` when available, then by `--select CSS`, `--heading "exact
   text"` (+ `--climb section`), or `--class-contains a,b` for Tailwind
   arbitrary classes.
2. **Fix** — the normal workflow (AGENTS.md, `design-system.md`, the gate).
3. **Reload** — keep `./run serve` running and wait for Phoenix's code reload.
   The shared Go browser driver waits for the LiveView connection, fonts,
   visible images, and stable target geometry; do not restore a fixed sleep or
   rebuild a release image for ordinary UI work.
4. **After-shot** — same command, same task/group and anchor, `--label after`.
   Then LOOK at both crops (Read the PNGs) — confirm the defect is actually gone
   and the full page shows nothing around it regressed — and hand the user the
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
after-shot taken against a stale server; a before-shot skipped
because the fix "was obvious"; reviewing only the crop and missing a regression
the full page would have shown.

**Scope + edges.**

- Responsive-sensitive fix → repeat both shots with `--width 390`.
- State behind a click can use `--click <selector>` (repeat for a multi-step
  reveal, each clicked in order); states beyond that use `./run capture console`
  or extend the browser driver under `tools/internal/browser/`.
- Console paths log in as the seeded `demo` account; use `EMAIL=` to shoot the
  staged `acme`/`globex` data volumes.
- This rule is for *user-reported fixes on rendered surfaces*. Building a new
  page/feature follows the design skills' own verification (full-page
  desktop+mobile review); no before exists there.

**Enforced.** Process rule (review): a UI-fix report with no before/after pair
in the conversation is incomplete. Mechanics: `./run shot` refuses to capture
without an in-progress task, auto-selects its task-owned output, and requires
`--task <id>` when ownership is ambiguous.

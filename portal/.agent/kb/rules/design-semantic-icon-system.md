# Rule: product code names icon meanings, never drawings

**Rule.** An icon is a semantic product asset, not a local decoration choice.
Every call site requests one namespaced meaning (`product.runner`,
`action.retry`, `state.offline`, `trust.permission_boundary`, …) from the
canonical registry. The registry owns the approved drawing and any optical
master. Product code never chooses a source-library glyph because it looks
close.

This is the load-bearing contract:

1. **One meaning, one canonical drawing.** The same concept uses the same
   master everywhere: navigation, metadata, empty states, buttons, docs, and
   marketing. Two semantic tokens may resolve to one master only when they
   intentionally express the same concept in different namespaces; they do
   not carry duplicated SVG.
2. **One drawing, one meaning.** Split an overloaded legacy glyph by intent.
   Loading, refresh, retry, replay, restore, and directory sync are not six
   aliases for a circular arrow. Approve, selected, verified, and declared are
   not interchangeable checkmarks.
3. **Name the operator's meaning.** Tokens describe the product concept, not
   the picture (`action.retry`, not `arrow_path`; `docs.credential_rotation`,
   not `key_with_arrows`). A later optical redraw must not rename call sites.
4. **Reuse before invention.** A new use starts with the semantic inventory.
   If the meaning exists, reuse it exactly. If it does not, add the meaning,
   context, and usage locations before drawing. Never introduce a near-
   duplicate to make one screen feel special.
5. **A decision button's icon is the plainest verb glyph.** Beside a verb
   label on an action button, gate rails, brackets, and container framing are
   product-NOUN language and turn to noise at 16 px — the founder read the
   rail-framed approve as "a black box with some line". `action.approve` is
   the bare check and `state.denied` the bare emphatic X; the label and tone
   carry the specifics. Universal symbols may legitimately recur across
   namespaces for the same underlying concept (the affirm check is also
   `state.included`'s drawing, exactly as `action.next` and
   `diagram.flow_right` share the arrow); the containers stay where they
   distinguish STATES — circle = failed, box = approved, shield = verified,
   disc = selected.

A licensed or Heroicons-derived drawing can still be an approved master, but
it is reached through its semantic token and its provenance stays recorded.

## Where the system lives

- `apps/emisar_web/priv/icons/<namespace>/<name>.svg` is the ONE master for
  `namespace.name`. Each file is a standalone, editable `<svg>` on the shared
  24-unit grid, so a geometry correction is an ordinary file edit and a normal
  diff. A sibling `<name>.16.svg` is that meaning's compact optical master; it
  earns its file only by rendering DIFFERENTLY from the regular one.
- `EmisarWeb.Icons` compiles those files in and is the only lookup surface.
  `master/2` picks the compact master at 16 px and below, and raises on a name
  it does not own — an unknown icon must fail loudly, never render nothing.
  A NEW master file recompiles the registry automatically: `@external_resource`
  only watches content that existed at compile time, so `__mix_recompile__?`
  watches the file LISTING — without it a freshly added meaning raises as
  unknown in dev until a full rebuild.
- `EmisarWeb.CoreComponents.icon/1` renders the master inline. Stroke weight
  belongs to the OUTPUT SIZE, not the file, so the component reads the size
  from the call site's `h-*` class and `assets/css/app.css` sets the weight per
  grid bucket.
- Semantic colour is CSS on the fragment's classes: `accent` (brand), `warn`
  (amber), `danger` (rose) recolour emphasis, while `selection` fills a whole
  silhouette and therefore follows `currentColor` — brand where the pick is a
  verdict, neutral where an authoring choice must not impersonate one.
- A gap between two crossing parts is a real `<mask>`, never a stroke painted
  in the surface colour. The product has many surfaces; a painted knockout is
  correct on exactly one of them. Mask ids are content-addressed, so two
  different masks can never collide and two identical ones are provably
  interchangeable when an icon repeats on a page.

## Drawing contract

- **Minimal, literal, and calm.** Preserve the fewest parts needed to recognize
  the noun, action, or state. Remove ornamental ticks, duplicate rails,
  unexplained arrows, tiny internal detail, and any line that does not improve
  recognition at 16 px. Product nouns may be distinctive; universal controls
  stay conventional enough to recognize without learning Emisar first.
- **One coordinate system.** First-party regular and compact masters use the
  same centered 24-unit grid, round caps and joins, and geometric-precision
  rendering. A local weight override is reserved for genuinely finer internal
  anatomy and needs native-size evidence. **The 24-grid masters sit on the
  half grid too** (`assets/icons/snap24.mjs`, displacement ≤0.25u): 24px
  renders 1:1 with the 1.5px stroke, and a half-grid coordinate doubled — the
  48px render — stays integer, so every first-party size is device-aligned.
  The masked/pixel-tuned exemptions keep their sub-quarter optical nudges.
- **Sibling families share their noun's exact construction, test-pinned.**
  After normalization every badge is byte-for-byte the same r 6.5 ring and
  every document the same sheet, differing only in modifier —
  `EmisarWeb.IconsTest` asserts the shared constructions so a family member
  cannot drift to its own outline.
- **Optical weight is an ON-SCREEN target, never a grid-unit constant — and
  the ramp is FINE at the small end.** A stroke value scales with the
  viewBox, so one unit number set for 24 px lands elsewhere at every other
  size. The renderer draws 1 px native at 16 (the one universally crisp
  weight — and what the pre-migration set drew at), ≈1.3 px at 20 through the
  zoomed viewBox, 1.55 px at 24 and above. Bolder was tried (≈1.6 px
  everywhere) and read clunky beside the type — the founder's old-vs-new
  comparison settled it: refinement at small sizes is thin + crisp + full
  contrast, never bulk. Judge any weight change at 1× device scale too, where
  fractional strokes blur worst. Pinned by `EmisarWeb.Components.IconTest`.
- **Compact is an optical master, not another icon.** The regular master is the
  default; a compact must preserve its metaphor and topology, and may enlarge,
  simplify, snap, or separate anatomy for the raster.
- **A compact cut on the NATIVE 16-unit grid, rendered 1:1, is the crisp
  path.** Projecting the 24 grid into a small box puts every coordinate
  between pixels — uniform blur no stroke weight fixes (the founder's "can we
  make icons more clear/sharp"). The cutter (`assets/icons/cut16.mjs`) scales
  each 24-grid drawing 2/3, OPTICALLY NORMALIZES it, and snaps to the half
  grid; masked, pixel-tuned, and transformed masters stay on the 24 grid and
  keep the zoomed projection.
- **Optical normalization is what makes a set feel professional: archetype
  targets, not one size.** Objects and badges fill the box to their class's
  ink target (round 14, square 13.5, wide 14 on the 16 grid — the round
  target computes to exactly the r 6.5 Heroicons badges use at this size),
  recentered on the box, growth capped at 1.16×. Operators are DELIBERATELY
  smaller — ×, −, +, chevrons, carets, arrows, and the balanced decision pair
  keep their glyph sizes (the Heroicons × is 47% of its box); the cutter's
  `KEEP_GLYPH_SIZE` list is that judgment, recorded. Before this pass 124 of
  133 cuts ran small at inconsistent sizes — the measured cause of "icons
  look smaller".
- **A hand-tuned cut declares `data-hand-cut` and the cutter never overwrites
  it.** Density is fixed by DELETING anatomy, not shrinking it: the seven
  densest cuts (organization, accounts, machine_client, manual_console,
  host_cluster, restricted, manual_coordination) are hand redrawn at ≤8
  strokes, and the spinner is hand-cut so its arc is exactly centered — an
  off-center arc visibly wobbles under `animate-spin`. Generated cuts keep
  every coordinate on the quarter grid, test-enforced; hand cuts are judged
  visually. A
  16-grid file declares `viewBox="0 0 16 16"`, renders 1:1 with a true 1 px
  stroke, and never re-enters the generator as a source (scaling a 16-grid
  file again shrinks it by another 2/3 — the generator guards this). **Its
  stroke centers sit on the HALF grid (.0/.5):** a 1 px stroke centered there
  puts both edges on device-pixel boundaries at EVERY integer display scale.
  (A 1.5 px stroke instead needs odd-quarter centers and is only clean at 2× —
  the bolder experiment lived there.) Deltas cannot be snapped independently
  (a lopsided hexagon), so the cutter absolutizes every path before snapping.
  **Contrast is the other half of perceived sharpness:** a chrome icon rides
  its row's own text tone, never a step dimmer — the rail's zinc-500 icons
  beside zinc-400 labels read as haze whatever the geometry did.
- **Outline is the family; fill is emphasis.** Do not maintain outline and
  filled editions as parallel icon sets. A filled part or state is earned only
  when selection or high salience needs it and the icon still belongs beside
  the outline family at every target size.
- **Perceived alignment is the finish line.** Start from measured geometry,
  then correct optically at the output size. Asymmetric shapes such as play
  triangles, clock hands, key teeth, badges, and arrowheads often need a nudge.
  A play or clock modifier must feel centered inside its ring; an arrowhead on
  a curve must be tangent to that curve, never merely close to its endpoint.
- **Negative space is structural.** Round caps may not overlap into blobs;
  rims, badges, and modifiers keep a visible knockout gap; lines that should
  connect do not stop short; doubled paths do not darken one edge. An element
  classed for accent color remains visible in monochrome and is never hidden
  when a token lacks that accent.

## Family contract

Related concepts share construction before they share style:

- inverse actions reuse one skeleton and reverse only the direction
  (upload/download, publish/use-published);
- circular actions reuse one ring, radius, center, and tangent-head grammar,
  then change only the semantic modifier (retry/replay/restore);
- paired states reuse the same noun or container and change a separated state
  modifier (declared/untrusted, online/offline, locked/restricted);
- trust concepts reuse the same boundary grammar where it is actually the
  subject, while the interior noun or verdict remains immediately legible;
- plural product nouns visibly derive from the singular noun instead of
  switching to an unrelated cluster metaphor.

Judge a new or changed icon beside its full alphabetical namespace, not alone.
It fails if it introduces the group's only unexplained container, different
stroke rhythm, unique corner language, or second metaphor for an existing
concept.

## Color and accessibility

- Base anatomy uses `currentColor`. Brand, amber, and rose may reinforce pass/
  added, pending/caution, and deny/failure, following `design-system.md`.
  Color is never the only carrier of meaning: every icon remains distinct and
  intact in monochrome.
- Accent classes recolor optional emphasis; they never control whether
  essential anatomy exists. A missing accent must not delete a keyhole, slider
  knob, exclamation dot, browser control, or any other structural part.
- **A semantic class marks emphasis inside a drawing. When it would cover the
  WHOLE drawing it is not emphasis — it is the anatomy, and anatomy paints in
  `currentColor` so the call site decides.** A fully-accented master cannot
  take its surface's color at all: the pricing page's deliberately muted free-
  plan checks came out brand emerald beside the paid plan's, and every loading
  spinner turned green in rows of zinc text. Sweep: a master whose every
  element carries `accent`/`warn`/`danger`.
- **A solid accent fill IS the accent, so an icon on one goes monochrome.** The
  emerald check inside `action.approve` was emerald on the emerald Approve
  button and all but vanished. The filled SURFACE carries `emisar-icon-mono`,
  which resets every semantic part to `currentColor`, so it covers whatever
  icon that surface ever hosts. Sweep: a solid `bg-{brand,amber,rose}-[456]00`
  face that can host an icon.
- **Chrome that LABELS renders icons monochrome; only content that REPORTS
  keeps its semantic accent.** A nav item, a menu row, a tab, a breadcrumb — the
  icon names a destination or a verb, and the row's own resting/hover/active
  colour already says everything about its state. Leaving the accents on lit
  half the console rail emerald at rest and left the active row with no signal
  of its own. The chrome element carries `emisar-icon-mono`. Sweep: a component
  that renders a caller-supplied `icon` inside navigation, a menu panel, or a
  tab strip. Pinned by `EmisarWeb.Components.NavBadgeTest` and
  `EmisarWeb.Components.DropdownTest`.
- **Every registry master inherits the surface — technology marks included.**
  The official Kubernetes blue was tried in the docs deploy list (founder call,
  then reversed the same day on seeing it in context): trademark ink inside
  first-party chrome reads as one foreign accent in a column of house-coloured
  siblings. A semantic token keeps the official SILHOUETTE and paints in
  `currentColor`; full-colour artwork belongs only to the locked `vendor.*`
  marks on their own surfaces (`design-console-ux.md` §7.38).
- An icon beside text that already states its meaning is decorative and hidden
  from assistive technology. An icon carrying unrepeated meaning gets an
  accessible name and the shared hover/focus tooltip. The visible glyph may be
  16–24 px; an interactive icon control still owns at least a 40×40 px hit area.
- Animation may show a real state change, but motion never supplies the only
  distinction. A static frame and reduced-motion rendering must remain clear.

## Brand and vendor boundary

- The Emisar logo is a locked brand asset. Do not redraw, simplify, recolor, or
  repurpose it as a generic product icon. Reuse the existing brand component or
  source asset byte-for-byte.
- Vendor marks retain official geometry and trademark colors. Normalize only
  their container, clear space, and optical size. Embedded SVG ids must be
  instance-safe, and clipping/masks must render non-empty in every instance.
- Official technology marks and product icons remain separate categories. Do
  not make a vendor logo look native by quietly altering its paths, and do not
  make a first-party icon look official by borrowing a vendor silhouette.

## Review gate

Source inspection is not visual proof. Every new master or geometry change
must complete this loop before product integration:

1. record the semantic token, literal meaning, and every intended usage;
2. draw the regular master and only the compact masters the raster needs;
3. render the changed icons and the complete selected catalog at literal
   16, 20, 24, and 48 px before any nearest-neighbour enlargement;
4. inspect those actual pixels for optical center, tangent direction, stroke
   rhythm, joins, clearances, disconnected anatomy, and subgroup consistency;
5. inspect dark, light, and monochrome output so color or one surface cannot
   hide a failure;
6. have independent optical and semantic reviewers inspect the same current
   renders; resolve every P0, P1, and material P2 finding;
7. obtain human approval, then verify representative in-product desktop and
   mobile screenshots before migrating the remaining call sites.

Any correction to approved geometry returns to step 2. Reviewer prose about an
older raster is superseded evidence; regenerate first, then review the new
pixels. Keep before/after/context evidence for a correction so the old meaning,
new master, and affected product usage remain traceable.

**Good:** `action.retry` resolves to the one approved retry loop everywhere;
its 16 px master preserves the same loop and modifier after an optical
correction.

**Bad:** one page chooses a generic refresh glyph for retry, another adds a
rose dot, and a third redraws the ring because each looked acceptable in
isolation.

**Sweep.** Search production templates and components for direct source-library
names, inline SVG fragments, copied paths, and local icon maps. Reconcile every
result to a semantic token or an explicit brand/vendor/structural exclusion.
Then inspect the registry for duplicate meanings, overloaded tokens, orphaned
masters, undocumented compact variants, and color-dependent anatomy.

**Enforced.** `EmisarWeb.IconsTest` checks unique ownership, namespacing,
XML-valid masters on the shared grid, compact masters that actually differ,
content-addressed mask ids, every mask defined exactly once for the page,
emphasis that never covers a whole drawing, masters that state no color of
their own, and the brand/vendor exclusion. `EmisarWeb.TemplateHygieneTest` reconciles every
literal icon name in every template against the registry, so a typo fails the
gate rather than the one page that renders it. Review enforces metaphor,
minimalism, optical alignment, family coherence, accessibility, and the
rendered-evidence loop; those judgments cannot be reduced safely to a source
grep.

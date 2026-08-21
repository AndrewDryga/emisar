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

During the registry migration, existing direct `hero-*` references are frozen
migration debt, not precedent. Do not add a new raw source-glyph choice. A
licensed or Heroicons-derived drawing can still be the approved master, but it
is reached through its semantic token and its provenance remains recorded.

## Drawing contract

- **Minimal, literal, and calm.** Preserve the fewest parts needed to recognize
  the noun, action, or state. Remove ornamental ticks, duplicate rails,
  unexplained arrows, tiny internal detail, and any line that does not improve
  recognition at 16 px. Product nouns may be distinctive; universal controls
  stay conventional enough to recognize without learning Emisar first.
- **One coordinate system.** First-party regular and compact masters use the
  same centered 24-unit grid, round caps and joins, and geometric-precision
  rendering. Default visible outline weights are `1.74` at 16 px, `1.64` at
  20 px, and `1.55` at 24 px and above. A local weight override is reserved for
  genuinely finer internal anatomy and needs native-size evidence.
- **Compact is an optical master, not another icon.** The regular master is the
  default. Add a dedicated 16 px master only when scaling loses a gap, center,
  silhouette, or modifier. It must preserve the regular master's metaphor and
  topology; it may enlarge, simplify, snap, or separate anatomy for the raster.
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

**Enforced.** The semantic registry is the only production lookup surface.
Validation checks token coverage, unique ownership, XML-valid fragments,
regular/compact availability, and locked brand/vendor assets. Review enforces
metaphor, minimalism, optical alignment, family coherence, accessibility, and
the rendered-evidence loop; those judgments cannot be reduced safely to a
source grep.

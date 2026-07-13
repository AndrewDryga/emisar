# Implementation Loop

Use this once a creative direction is selected.

## Build Order

1. Establish page-level tokens: color variables, type scale, spacing rhythm,
   section constraints, image treatment, and motion preferences.
2. Build the first viewport and navigation. Verify the brand/product/category is
   obvious without scrolling.
3. Build proof/mechanism sections before decorative sections.
4. Add CTA and trust/FAQ sections only after the narrative is clear.
5. Add motion and interaction last, with `prefers-reduced-motion`.

## Rendering Checks

Capture screenshots at minimum:

- Desktop wide: 1440 x 1000
- Desktop narrow: 1024 x 900
- Mobile: 390 x 844
- Short viewport: 1440 x 700

Check:

- Text does not overlap, truncate badly, or resize layout unexpectedly.
- The first viewport hints at the next section.
- Primary CTA remains visible or quickly discoverable.
- Product-specific visual assets load and are legible.
- Mobile layout is designed, not merely stacked.
- Hover/focus states are visible and stable.
- Motion does not hide content or create layout shift.

## Verification

- Run the project compile/format/test gate required by the touched project.
- Use browser screenshots before calling the page done.
- Check initial HTML contains real content for crawlers.
- Check title/meta/canonical/schema/internal links where the page requires them.
- Check image dimensions, alt text, contrast, keyboard focus, reduced motion, and
  no horizontal overflow.

## Review Loop

After the first complete render:

1. Run `design-review`.
2. Fix blockers and majors first.
3. Re-render the same viewport set.
4. Run `design-review` again if visual structure, copy, or interaction changed.

# Quality Rubric

Use scores to calibrate judgment. Do not average them into a fake objective grade;
use them to identify the next fix.

## Distinctiveness

1. Could be a generic SaaS template with the logo changed.
2. Has one unusual detail but standard structure dominates.
3. Has a recognizable product-specific idea in key sections.
4. Uses a coherent art direction that would be hard to reuse for another product.
5. Feels authored: concept, copy, layout, motion, and proof reinforce one idea.

## Clarity

1. Buyer cannot tell what the product does.
2. Category is visible but value is vague.
3. Value is clear after scanning several sections.
4. First viewport communicates category, value, and CTA.
5. Page teaches the mechanism and value without slowing the buyer down.

## Trust And Proof

1. Relies on unsupported adjectives.
2. Mentions security/trust but lacks mechanism.
3. Shows some proof but leaves key objections unanswered.
4. Uses concrete mechanism, examples, and security constraints.
5. Makes the trust model legible and credible to a skeptical operator.

## Visual Craft

1. Broken spacing, hierarchy, or alignment.
2. Basic but inconsistent.
3. Solid composition with some weak sections.
4. Strong rhythm, type, imagery, and responsive detail.
5. Agency-grade craft across all sections and viewports.

## UX And Accessibility

1. Primary path broken or inaccessible.
2. Works only on desktop/happy path.
3. Usable with some mobile/focus/contrast issues.
4. Clear scan path, mobile layout, focus, contrast, and reduced-motion behavior.
5. Excellent usability under real buyer scanning behavior.

## SEO And Performance

1. Crawl, metadata, or load is broken.
2. Content exists but semantics/performance are weak.
3. Acceptable basics with missing structured/internal details.
4. Strong server-rendered content, metadata, links, and asset discipline.
5. SEO and performance support the creative idea without compromise.

## Verdict Rules

- Any score of 1 in clarity, trust, UX/accessibility, or SEO/performance is
  `RETHINK` or `SHIP-AFTER-FIXES` with blockers.
- Distinctiveness below 3 means the design has not escaped template territory.
- Visual craft below 3 means screenshots must be fixed before shipping.
- False or overbroad security claims are always blockers.

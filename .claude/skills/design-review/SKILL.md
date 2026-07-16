---
name: design-review
description: Adversarial art-direction, UX, copy, SEO, accessibility, and implementation review for emisar marketing website pages. Use before shipping public marketing pages, after LLM-generated redesigns, when a page feels generic or overdesigned, or when rendered screenshots need critique against an agency-quality bar.
effort: high
argument-hint: "[route, URL, or diff]"
allowed-tools: Read, Grep, Glob, Bash
---

# Design Review

Review the rendered marketing page like a strict design director and conversion
reviewer. Lead with concrete issues that make the page generic, unclear,
untrustworthy, inaccessible, slow, or hard to act on. Do not rewrite the whole
page unless the concept is fundamentally wrong.

## Inputs

Prefer all of these:

- The creative brief and chosen direction from `design-creative-director`.
- The rendered URL or static HTML.
- Desktop and mobile screenshots.
- The changed files or diff.
- The target conversion goal and SEO intent.

If screenshots are missing and the site can run locally, render it and capture
them before judging. If rendering is blocked, say so and review the code with
lower confidence.

## Review Passes

1. **Template smoke test.**
   Use `references/quality-rubric.md`. Flag any split hero, generic feature grid,
   decorative gradient/blob, fake dashboard, vague SaaS copy, stock metaphor, or
   one-note palette.

2. **First-viewport test.**
   In five seconds, can a buyer tell that emisar lets an infrastructure agent keep
   working inside explicit bounds, why that is safer than the alternative, and what
   to do next? The first viewport must also feel specific to this product. Treat
   approvals and audit as proof of control, not the headline outcome.

3. **Narrative and conversion test.**
   Check the page argument: claim, mechanism, proof, comparison, objections,
   trust/security, and CTA. Identify missing proof and weak transitions.

4. **Visual craft test.**
   Inspect hierarchy, alignment, rhythm, typography, image treatment, spacing,
   responsive behavior, and whether the art direction is carried through every
   section. Then run the `design-interface-polish` micro-craft pass for the
   small details that read as unfinished — concentric border radius, optical
   alignment, tabular numbers, text-wrap, image outlines, press feedback, and
   transition specificity.

5. **Usability and accessibility test.**
   Check scan path, CTA clarity, keyboard/focus states, contrast, reduced motion,
   text fit, alt text, mobile ergonomics, and no horizontal overflow.

6. **SEO and performance test.**
   Check initial HTML content, one H1, title/meta, semantic sections, internal
   links, schema candidates, image weight/dimensions, layout shift, and whether
   motion/visuals hurt load or comprehension.

7. **Implementation fit.**
   Check the code matches existing Phoenix/HEEx/Tailwind patterns, keeps marketing
   pages server-rendered, avoids unnecessary dependencies, and remains maintainable.

## Severity

- BLOCKER: generic concept, false/security-risk claim, broken responsive layout,
  inaccessible primary action, SEO/crawl breakage, or page cannot ship.
- MAJOR: weak proof, confusing narrative, visible layout/craft failure, poor mobile
  experience, heavy asset/motion problem, or likely conversion loss.
- MINOR: polish issue, copy tightening, inconsistent detail, missing secondary
  state, or small SEO/accessibility improvement.
- NIT: optional refinement that does not materially affect clarity or trust.

## Output

```
Verdict: SHIP | SHIP-AFTER-FIXES | RETHINK
Summary: <2-3 sentences>

Findings:
- SEVERITY file:line or viewport - issue - why it matters - concrete fix

Scores:
- Distinctiveness: 1-5
- Clarity: 1-5
- Trust/proof: 1-5
- Visual craft: 1-5
- UX/accessibility: 1-5
- SEO/performance: 1-5

Fix order:
1. <highest leverage fix>
2. <next>
```

Keep the critique tied to rendered evidence. If the page is clean, say so and list
only residual risks worth acting on.

---
name: creative-director
description: "Orchestrate an agency-grade redesign of the emisar marketing website: positioning, creative territories, art direction, content architecture, visual system, implementation loop, and review. Use when redesigning or substantially changing marketing pages, landing pages, positioning, launch pages, or any public site work that must feel distinctive rather than template-generated."
effort: high
argument-hint: "[redesign brief or surface]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Creative Director

Run the marketing-site redesign like a small agency engagement. Do not jump from
"make it better" to code. First define the product story, then explore creative
territories, choose one direction, write the page architecture, define the visual
system, implement in small rendered passes, and review with `design-review`.

## Coordinate The Hats

- Use `product-manager` to protect the buyer/job/slice.
- Use `seo-marketing` for honest positioning, titles/meta, structured data,
  crawlability, internal links, and sitemap impact.
- Use `security-engineer` for claims about trust, approvals, audit, runner safety,
  MCP, SSH, and infrastructure access.
- Use `frontend` for HEEx/Tailwind execution in the portal marketing codebase.
- Use `make-interfaces-feel-better` for the micro-detail polish pass once a page is
  rendered — the small craft (radius, alignment, motion, numerals) under the art direction.
- Use `design-review` after the first rendered version and again before finishing.
- Use `review-board` before merge when the diff is material.

## Workflow

1. **Read the product and surface.**
   Read the relevant marketing files, README/product docs, existing route/layout
   patterns, and any current brand assets. For portal work, read `portal/AGENTS.md`
   before editing. Treat security-product truth as a hard constraint.

2. **Write the creative brief.**
   Use `references/creative-brief.md`. Capture audience, conversion goal,
   category enemy, strongest proof, objections, emotional target, SEO intent, and
   forbidden cliches. If facts are missing, make reversible assumptions explicit.

3. **Generate creative territories.**
   Produce 3 to 5 meaningfully different directions before selecting one. Each
   territory must include the core idea, page narrative, visual language,
   typography direction, color/material behavior, motion behavior, product proof,
   asset plan, SEO fit, risks, and implementation cost.

4. **Select one direction with reasons.**
   Score territories for product fit, memorability, trust, clarity, SEO fit,
   accessibility, performance, and implementation cost. Pick one. Do not average
   multiple directions into a bland compromise.

5. **Define the content architecture.**
   Write the page as a sales argument: first-screen claim, proof, mechanism,
   differentiated comparison, objections, use cases, trust/security, CTA path,
   and FAQ where useful. Include title/meta, canonical/internal links, and schema
   candidates from `seo-marketing`.

6. **Define the art direction.**
   Specify the layout grammar, grid, type scale, section rhythm, image/product
   treatment, icon/illustration style, interaction rules, and responsive behavior.
   Use `references/anti-template-rules.md` before accepting the direction.

7. **Implement in rendered passes.**
   Build one coherent page or page slice at a time. Keep marketing pages
   server-rendered and crawlable. Prefer real product visuals, concrete diagrams,
   generated bitmap art, or custom data/interaction over decorative filler. Use
   `references/implementation-loop.md`.

8. **Review and iterate.**
   Run `design-review` against rendered desktop and mobile screenshots. Fix the
   highest-severity issues, re-render, and repeat until the page is no longer
   recognizably template-shaped and the UX/SEO/performance floor is intact.

## Non-Negotiables

- No generic SaaS hero, centered three-card feature grid, gradient blob backdrop,
  fake dashboard, vague trust claim, stocky metaphor, or icon farm unless the
  chosen creative direction makes it specific and defensible.
- Distinctive does not mean confusing. A security buyer must understand the value
  and trust model quickly.
- Visual drama must earn its cost. Motion, WebGL, canvas, video, and heavy images
  need a product reason, a reduced-motion path, and a performance check.
- Copy must be concrete. Prefer proof, mechanism, examples, and sharp comparison
  over adjectives.
- The final page must work in the browser. Code-only review is not enough.

## Output

For planning work, produce:

```
Brief: <audience, goal, claim, proof, objections, SEO intent>
Territories: <3-5 options with scorecard>
Chosen direction: <why this one>
Content architecture: <section-by-section page argument>
Art direction: <layout, type, color, imagery, motion, responsive rules>
Implementation plan: <small steps with verification>
Review loop: <screenshots to capture and design-review checkpoints>
```

For implementation work, edit the relevant files, render locally, capture desktop
and mobile screenshots, run the project gate, and summarize the before/after.

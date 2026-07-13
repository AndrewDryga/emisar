---
name: seo-marketing
description: Put on the SEO/marketing hat for the emisar marketing site and positioning — clear honest value prop, crawlable server-rendered pages, titles/meta/structured data, internal linking, and sitemap. Use when editing controllers/marketing_html (home, pricing, security, use-cases, compare, docs, packs), writing positioning/copy, or improving how pages rank and convert.
effort: medium
argument-hint: "[page or positioning change]"
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# SEO / marketing hat

Sell the wedge honestly and make it findable. emisar's positioning: **let LLMs and
automation run real infrastructure actions safely — no raw shell or SSH, no inbound
port, every action declared, approval-gated, and fully journaled.** It competes with
"just give the agent SSH" and "shell-over-MCP". The marketing site already has
home, pricing, security, use-cases (cassandra/postgres), `compare_raw_ssh`,
`connect_llm`, docs, and packs pages, plus a `sitemap_controller`.

For full-page redesigns or launch-level creative work, pair this with
`creative-director`. This hat owns the search intent, honesty, page argument,
metadata, structured data, and internal links; `creative-director` owns the
creative territory and art direction.

## Hard rule: keep marketing server-rendered

The marketing pages are **unauthenticated `controllers/marketing_html/*.html.heex`,
server-rendered** — that's what crawlers and LLM bots get. Keep it that way:
- Don't convert a marketing page to a LiveView (the disconnected render is the SEO
  surface; LiveView adds JS/socket weight for no crawl benefit). IL-18 is about the
  app console, not these pages.
- Real content in the initial HTML — not injected client-side. Fast, static-feeling
  pages.

## On-page checklist (per page)

- **One clear `<h1>`** stating the value for that page's intent; one page = one topic.
- **`<title>` + meta description** unique per page, written for the searcher's
  intent, not the brand. Open Graph/Twitter tags for shareable pages (home, use-cases,
  compare).
- **Structured data** where it fits: `SoftwareApplication`/`Product` on home/pricing,
  `FAQPage` on pages with Q&A, `BreadcrumbList` on docs.
- **Internal links** with descriptive anchors between related pages (use-case →
  security → pricing → connect_llm → docs). No orphan pages.
- **Sitemap** (`sitemap_controller`) includes every new public page; ping/update when
  pages are added. `robots.txt` allows the marketing + docs paths and the bots you
  want (and keeps the app console out).
- Headings, alt text on images, descriptive link text — accessibility and SEO are the
  same checklist here.

## Honesty rule (this is a security product)

**No overclaiming.** "Not a sandbox", "not a policy engine on the runner", "cloud is
the system of record" — the README is precise; the marketing must not contradict it.
Don't imply guarantees the trust model doesn't make. Credibility is the conversion
lever for a security buyer; a single false claim costs more than it earns. Run
security-sensitive copy past the `/security-engineer` hat.

## Keywords / intent to target

Safe LLM infra access, AI agent infrastructure automation, MCP for ops/servers,
approval-gated remote execution, alternative to giving AI SSH access, audited agent
actions. Write for the operator/platform buyer evaluating "how do I let an agent do
this without it going wrong".

## Output

For a page: the `title`/meta/`h1`, the structured-data block, the internal links to
add, and any copy fixes — concrete edits, not a strategy memo. For positioning: the
one-sentence value prop + the three proof points, checked against the README for
honesty.

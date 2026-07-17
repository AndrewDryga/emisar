# Marketing headlines are flat statements, not aphorisms

## Rule

Every marketing headline — the H1, section h2s, card titles, the final CTA — is a
flat, direct statement in one of three shapes:

1. **Category claim:** what the product is, for whom. "Secure infrastructure
   access for your AI agents."
2. **Benefit statement:** what the reader gets, plainly. "Your agent works from
   live production data." / "Connect your first runner in five minutes."
3. **Concrete inventory:** the actual things, listed. "Approved actions, policy
   checks, and a full audit trail." / "Least agency, deny by default, human
   approval, immutable audit."

The bar is tailscale.com: "Auditable access to SSH, K8s, databases, and more.",
"Installation takes minutes." — you always know exactly what is being said, and
nothing reads as writing-about-writing.

Banned headline shapes (each shipped here and was rejected):

- **Comma-flourish:** "The alternatives, honestly." / "Two incidents, in full." /
  "The skeptical questions, answered."
- **Riddle / reveal:** "Your agent has read everything except your production." /
  "Your AI is brilliant. And blind."
- **Wordplay / zeugma:** "Leave your AI agent working in production — not holding
  your SSH key."
- **Abstract poetry:** "A catalog, a gate, and a ledger."
- **Fragment drumbeat / mirror:** "Pay per runner. Not per seat." / "Give your AI
  production access. You keep the last word."

## Why

Founder correction, 2026-07-17 ("If anything it got worse. Inspire by tailscale"):
an aphoristic headline system reads as performance. Each individual line can seem
clever, but a page of them makes the reader decode the writer instead of learning
the product. Flat statements compound — every heading answers a question; the page
gets clearer as it accumulates. Aphorisms compound too — the page gets more
mannered as it accumulates.

## ✅ Good

- "Secure infrastructure access for your AI agents."
- "emisar vs. SSH keys and custom MCP servers."
- "Priced per runner, not per seat."
- "Watch an agent work a real incident."
- "Frequently asked questions"

## ❌ Bad

- "The framework a frontier lab published — enforced by emisar." (coy + flourish)
- "Built so your security team says yes." (reveal-shaped)
- "Boring, defensible defaults." (aphorism)
- Any heading you could imagine on a poster rather than in an answer.

## How it's enforced

Editorial judgment via `content-director` — headlines are exempt from the
competitor-swap test in exchange for being flatly informative. Sweep target:
every `marketing_html/*.heex` h2/display heading (`grep -n "text-4xl font-bold"
… marketing_html/`); the sweep across non-home pages is queued as portal task
`2026-07-17-marketing-pages-informative-headline-in-the-h2-e` (tag swap + this
register together).

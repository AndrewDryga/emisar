---
name: oauth-consent-form-action
description: ChatGPT's sandboxed OAuth document needs a consent-only HTTPS form-action source; rejected requests and every other page keep the strict self-only policy
subsystem: portal
sources: [portal/apps/emisar_web/lib/emisar_web/controllers/oauth_controller.ex, portal/apps/emisar_web/lib/emisar_web/plugs/content_security_policy.ex]
updated: 2026-07-20
---

The base browser policy uses `form-action 'self'`. The OAuth consent response is
the one exception: ChatGPT's sandboxed authorization document has rejected both
`'self'` and explicit host sources for the same-origin consent POST, so the
validated consent page adds the `https:` scheme source through `:csp_extra`
(`oauth_controller.ex:191-223,242-261`).

Keep the relaxation after `fetch_client` and the exact registered redirect URI
check (`oauth_controller.ex:68-79`). Rejected requests render the normal strict
policy. Do not move `https:` into the base directives. Because the consent-page
CSP permits any HTTPS form target as browser compatibility defense-in-depth,
the form action must remain a fixed application route and all rendered client
metadata must remain escaped.

The CSP plug builds its header in `register_before_send`, so controller-assigned
extras are merged at response time (`content_security_policy.ex:43-67`).

## Changelog
- 2026-07-20 — created after the ChatGPT consent POST remained blocked with explicit server and callback host sources

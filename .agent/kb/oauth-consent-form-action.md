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

The controller assigns the relaxation only after `fetch_client` and the exact
registered redirect URI check (`oauth_controller.ex:68-79`). Rejected requests
render the normal strict policy, and the base directives remain self-only. The
consent form posts to a fixed application route and rendered client metadata is
escaped, which bounds the broader HTTPS scheme source used by this response.

The CSP plug builds its header in `register_before_send`, so controller-assigned
extras are merged at response time (`content_security_policy.ex:43-67`).

Related rule: [browser security exceptions stay response-local](rules/shared-browser-security-exceptions-stay-response-local.md).

## Changelog
- 2026-07-20 — created after the ChatGPT consent POST remained blocked with explicit server and callback host sources

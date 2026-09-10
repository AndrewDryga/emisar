---
name: oauth-consent-form-action
description: ChatGPT's sandboxed OAuth document needs the consent response's form-action to allow the https scheme plus the endpoint and registered-callback origins; rejected requests and every other page keep the strict self-only policy
subsystem: portal
sources: [portal/apps/emisar_web/lib/emisar_web/controllers/oauth_controller.ex, portal/apps/emisar_web/lib/emisar_web/plugs/content_security_policy.ex]
updated: 2026-09-10
---

The base browser policy uses `form-action 'self'`. The OAuth consent response is
the one exception: ChatGPT's sandboxed authorization document has rejected
`'self'` alone for the same-origin consent POST, so the validated consent page
extends `form-action` through `:csp_extra` with three kinds of source
(`allow_oauth_form_navigation/2` in `oauth_controller.ex`): the `https:` scheme,
the portal endpoint's own origin, and the origin of the registered redirect URI —
the last two kept explicit so a local `http` endpoint and a registered loopback
callback still work where a scheme source alone would not.

The controller assigns the relaxation only after `fetch_client` and the exact
registered redirect URI check (`validate_authorization_request/2`), so the
redirect origin that reaches the list is client-supplied but already
exact-match validated. Rejected requests render the normal strict policy, and
the base directives remain self-only. The consent form posts to a fixed
application route and rendered client metadata is escaped, which bounds the
broader scheme source used by this response.

The CSP plug builds its header in `register_before_send`, so controller-assigned
extras are merged at response time (`put_csp_header/2` in
`content_security_policy.ex`).

Related rule: [browser security exceptions stay response-local](rules/shared-browser-security-exceptions-stay-response-local.md).

## Changelog
- 2026-09-10 — the form-action list also carries the endpoint and registered-callback origins, not only the https scheme; line citations replaced with function names
- 2026-07-20 — created after the ChatGPT consent POST remained blocked with explicit server and callback host sources

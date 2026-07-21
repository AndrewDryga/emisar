---
name: oauth-sign-in-return-to
description: A protected OAuth GET stores its exact local path in the signed session; magic-link, registration, and SSO sign-in must preserve it through consent
subsystem: portal
sources: [portal/apps/emisar_web/lib/emisar_web/user_auth.ex, portal/apps/emisar_web/lib/emisar_web/controllers/user_session_controller.ex, portal/apps/emisar_web/lib/emisar_web/controllers/sso_controller.ex]
updated: 2026-07-20
---

`require_authenticated_user` stores the complete local GET path, including the
OAuth query string, as `:user_return_to` before redirecting a signed-out user to
`/sign_in`. `UserAuth.log_in_user/5` reads that signed-session value before
renewing the session and uses it as the post-login redirect.

Magic-link sign-in and first-time registration keep this value unless a
validated branded `/app/<account>` path explicitly replaces it. The SSO
callback also preserves an existing value and only defaults to its IdP account
when the protected request did not provide one. This is what returns cloud LLM
OAuth flows to consent regardless of which visible sign-in method the user
chooses.

The OAuth return path is never accepted from an SSO callback parameter. It
originates from Phoenix's current request path inside the signed session;
client-supplied magic-link return paths remain restricted by `ReturnTo` to a
local `/app/<account>` shape.

Keep regression coverage for existing-user magic-link sign-in, first-time
registration, and SSO. Each path must return to the exact original
`/oauth/authorize?...` URL and render consent.

## Changelog
- 2026-07-20 — created after the OAuth publication check found SSO overwrote the protected return path with its account dashboard

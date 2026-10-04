---
name: oauth-sign-in-return-to
description: a protected OAuth GET stores its exact local path in the signed session; every workspace sign-in (email code, sign-up, invitation, SSO) returns to it through consent
subsystem: portal
sources: [portal/apps/emisar_web/lib/emisar_web/user_auth.ex, portal/apps/emisar_web/lib/emisar_web/controllers/user_session_controller.ex, portal/apps/emisar_web/lib/emisar_web/controllers/sso_controller.ex]
updated: 2026-10-04
---

`require_signed_in` guards the pages that name no workspace (OAuth consent,
`/activate`, `/app` and its shorthands, billing selection, the checkout return).
When the browser holds no live workspace session, it stores the complete local GET
path, including the OAuth query string, as `:user_return_to` (only when it fits the
cookie) and redirects to `/sign_in`, the workspace picker.

Every sign-in completion (email code, sign-up, invitation, SSO) reads that value
before renewing the session and returns to it only when the router says the path
either names no workspace (a `require_signed_in` page) or belongs to the workspace
just signed in to; anything else lands on that workspace. That is what brings a
cloud LLM's OAuth flow back to consent whichever workspace and sign-in method the
person uses. Only this server writes the path; a request parameter or an SSO callback
has no way to supply it.

Regression coverage (`oauth_controller_test.exs`): an existing Member's email-code
sign-in and a sign-up that creates a new workspace both resume the exact
`/oauth/authorize?...` request and render consent. The SSO and invitation paths
share the same `return_path_for/2` rule.

## Changelog

- 2026-10-04 — per-workspace sign-in: `require_signed_in` and the router check replace `require_authenticated_user` and `ReturnTo`.
- 2026-07-20 — created after the OAuth publication check found SSO overwrote the protected return path with its account dashboard
- 2026-08-02 — refreshed the installer name: `UserAuth.log_in_user/5` split into per-provenance installers (`log_in_magic_link_user/4`, `log_in_magic_link_mfa_user/4`, `log_in_sso_user_for_account/5`), so the card names the installers as a group rather than one function

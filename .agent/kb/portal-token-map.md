---
name: portal-token-map
description: every bearer credential the portal mints, its table, prefix, owning context, and mint/verify/revoke entry points — there is deliberately no single tokens table
subsystem: portal
sources: [portal/apps/emisar/lib/emisar/api_keys.ex, portal/apps/emisar/lib/emisar/oauth.ex, portal/apps/emisar/lib/emisar/runners.ex, portal/apps/emisar/lib/emisar/auth.ex, portal/apps/emisar/lib/emisar/auth/user_token/query.ex, portal/apps/emisar/lib/emisar/accounts.ex, portal/apps/emisar/lib/emisar/sso.ex, portal/apps/emisar/lib/emisar/admin.ex, portal/apps/emisar/lib/emisar/crypto.ex]
updated: 2026-10-05
---

The token map — the one place to understand every bearer credential emisar
mints, and which context owns it.

There is deliberately **no** single tokens table: each credential has its own
table and a single owning context that mints / verifies / revokes it. A SIEM
log-shipping token is not an LLM-bridge key is not a runner session — keeping
them apart keeps each lifecycle (and its abuse surface) reviewable in
isolation. All secret generation, hashing, and constant-time comparison live
in `Emisar.Crypto` — the single crypto-review surface; no context implements
them inline.

## The credentials

| Credential | Table | Prefix | Owner | Mint | Verify | Revoke |
|---|---|---|---|---|---|---|
| MCP / LLM-bridge key & SIEM audit-export token (split by `kind`) | `api_keys` | `emk-` | `Emisar.ApiKeys` | `create_key/2`, `create_service_account_key/3`, `mint_quick_key/1` | `peek_api_key_by_secret/1` | `revoke_api_key/2` |
| OAuth access / refresh token & auth code | `oauth_tokens`, `oauth_authorization_codes` | `emo-` / `emor-` / `emoc-` | `Emisar.OAuth` | `issue_code/4` → `exchange_code/1`, `refresh/1` | `resolve_access_token/2` | expiry sweeps (`delete_expired_authorization_codes/1`, `delete_unused_clients/1`) |
| Runner enrollment key | `runner_enrollment_keys` | `emkey-enroll-` | `Emisar.Runners` | `create_enrollment_key/2` | `register_via_enrollment_key/3` claims a use inside its transaction (`peek_enrollment_key_by_secret/1` is a read-only inspector, not the gate) | `revoke_enrollment_key/2` |
| Runner session token | `runner_tokens` | `rnrtok-` | `Emisar.Runners` | `mint_runner_token/3` | `verify_runner_token/1` | disable or delete the runner; a 90-day `expires_at` refused at verify, rotated by `refresh_runner_token/1` |
| Workspace session, emailed sign-in and sign-up codes, MFA enrollment, provider-verification and email-change codes | `auth_user_tokens` (every row but `sign_up` belongs to one workspace and one Member) | binary (unprefixed); codes are split into a browser nonce and an emailed code | `Emisar.Auth` | `request_magic_link/3`, `request_invitation_code/2`, `request_sign_up_code/2`, `resend_email_code/2`; sessions from `complete_magic_link_sign_in/4`, `complete_magic_link_mfa_sign_in/4`, `complete_sign_up/3`, `complete_sso_sign_in/5`, `SSO.complete_invitation_sso_sign_in/4`; email change: `begin_email_change/2` and `resend_email_change_code/2` (current inbox), then `confirm_email_change/3` (new inbox) | `fetch_session_by_token/2` (the token AND the workspace in the URL), `list_live_sessions/1`, `verify_magic_link/4`, `complete_email_change/4`; every request re-applies `UserToken.Query.authorized/1` | `complete_browser_sign_out/3` (every session of the browser), `revoke_session_tokens/3` (displaced or evicted cookie entries), `revoke_session/2`, `revoke_and_disconnect_other_sessions/2`, `delete_membership_sessions/2`, `delete_identity_sessions/2`, `delete_account_email_sessions/2`; a completed email change deletes the Member's address-bound codes; 60-day absolute session expiry, 15 minutes for an email-change code |
| Staff sign-in code and staff session | `admin_staff_tokens` | binary (unprefixed); the sign-in code is split like the workspace code | `Emisar.Admin` | `request_staff_sign_in/2`, then `complete_staff_sign_in/5` (emailed code AND authenticator code) | `fetch_staff_session/1`, `refresh_staff_session/1` | `delete_staff_session/1`, `reset_staff/1`, `remove_staff/1` (box commands); 12-hour absolute expiry |
| Account invitation | `account_memberships.invitation_token_digest` | binary (unprefixed) | `Emisar.Accounts` | `invite_user_to_account/2`, `resend_account_invitation/2` | `fetch_invitation_by_token/2`; final acceptance rechecks the exact digest and invited address | acceptance, resend, membership removal, or seven-day expiry |

## One session, one Member

A workspace session row names its workspace and Member, and an SSO session also
freezes the identity's issuer and subject; the per-request predicate re-checks the
Member (live, not suspended, not pending), the workspace (live, not disabled) and,
for SSO, that identity and its provider. Nothing else carries session authority.
The browser keeps up to six `{workspace, token}` entries in its cookie and a
per-browser id whose digest every session stores, so sign-out ends every session of
that browser, including one a racing tab minted. A cookie entry displaced by a new
sign-in or evicted by the cap is revoked in the same request and audited.

Removing or suspending a Member, retiring or re-linking its SSO identity, and turning
`require_sso` on (for email-code sessions) delete the affected rows and disconnect
their sockets. A disabled workspace's sessions stop passing the predicate and its open
LiveViews leave on the lifecycle broadcast. A connected LiveView also leaves at the
session's absolute expiry.

## Credentials that are NOT token tables

The inbound **SCIM bearer** (`ems-`) lives as a hashed column on
`Emisar.SSO.IdentityProvider`, not its own table — it's one secret per
configured IdP, rotated as part of that provider's config, and verified at the
SCIM boundary by `Emisar.SSO.authenticate_scim_token/1`.

Account invitation digests live on their pending membership row because the
membership owns the acceptance, rotation, address binding, and expiry as one
lifecycle.

## Changelog

- 2026-10-05: a Member who signs in by email can change it again. Two `auth_user_tokens`
  contexts, both bound to that Member's row version: `email_change` (current inbox, skipped
  when the Member has an authenticator) and `email_change_new` (the new inbox).

- 2026-10-04: an MCP key or OAuth grant may act as a service account (a Member an
  app connects as): `ApiKeys.create_service_account_key/3`, and `OAuth.issue_code/4`
  takes the grantee. Neither adds a credential type; both bind `created_by_membership`
  to the service account and record the issuing person in `issued_by_membership_id`.

- 2026-10-04: one session row per workspace Member (Firezone model); member grants,
  personal proof routes, email change and confirmation tokens are gone; added the
  staff realm's tokens.

- 2026-09-23: new-address proof binds only the MFA enrollment and has no explicit
  cancel; replacement and expiry retire an abandoned proof.

- 2026-09-23: distinguished frozen Member grants and independent proof deadlines
  from bearer credentials, local revocation and whole-browser logout.

- 2026-09-22: documented session-bound new-address proof and corrected the Auth
  token table name against its current schema.

- 2026-08-26: moved verbatim from the compiled documentation-only module
  `Emisar.Tokens` (deleted — a zero-behavior BEAM module is not the home for
  repository knowledge).

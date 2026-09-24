---
name: portal-token-map
description: every bearer credential the portal mints, its table, prefix, owning context, and mint/verify/revoke entry points — there is deliberately no single tokens table
subsystem: portal
sources: [portal/apps/emisar/lib/emisar/api_keys.ex, portal/apps/emisar/lib/emisar/oauth.ex, portal/apps/emisar/lib/emisar/runners.ex, portal/apps/emisar/lib/emisar/auth.ex, portal/apps/emisar/lib/emisar/accounts.ex, portal/apps/emisar/lib/emisar/sso.ex, portal/apps/emisar/lib/emisar/crypto.ex]
updated: 2026-09-23
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
| MCP / LLM-bridge key & SIEM audit-export token (split by `kind`) | `api_keys` | `emk-` | `Emisar.ApiKeys` | `create_key/2`, `mint_quick_key/1` | `peek_api_key_by_secret/1` | `revoke_api_key/2` |
| OAuth access / refresh token & auth code | `oauth_tokens`, `oauth_authorization_codes` | `emo-` / `emor-` / `emoc-` | `Emisar.OAuth` | `issue_code/3` → `exchange_code/1`, `refresh/1` | `resolve_access_token/2` | expiry sweeps (`delete_expired_authorization_codes/1`, `delete_unused_clients/1`) |
| Runner enrollment key | `runner_enrollment_keys` | `emkey-enroll-` | `Emisar.Runners` | `create_enrollment_key/2` | `register_via_enrollment_key/3` claims a use inside its transaction (`peek_enrollment_key_by_secret/1` is a read-only inspector, not the gate) | `revoke_enrollment_key/2` |
| Runner session token | `runner_tokens` | `rnrtok-` | `Emisar.Runners` | `mint_runner_token/3` | `verify_runner_token/1` | disable or delete the runner; a 90-day `expires_at` refused at verify, rotated by `refresh_runner_token/1` |
| User session, magic-link, email-confirm | `auth_user_tokens` | binary (unprefixed) | `Emisar.Auth` | `complete_magic_link_sign_in/5`, `complete_sso_account_sign_in/4`, `complete_sso_session_step_up/4`, `request_magic_link/3`, `deliver_confirmation_instructions/1` | `fetch_session_by_token/1`, `verify_magic_link/4` | `complete_session_sign_out/2`, `delete_session_token/1`, `revoke_session/2`, `delete_all_session_tokens/1` |
| New sign-in address proof (`email_change_new`) | `auth_user_tokens` | split browser nonce and emailed code | `Emisar.Auth` | `confirm_email_change/4` after current-inbox or TOTP proof | `complete_email_change/5` with the browser nonce and a live personal session | successful completion, replacement, or 15-minute expiry |
| Account invitation | `account_memberships.invitation_token_digest` | binary (unprefixed) | `Emisar.Accounts` | `invite_user_to_account/2`, `resend_account_invitation/2` | `fetch_invitation_by_token/2`; final acceptance rechecks the exact digest and invited address | acceptance, resend, membership removal, or seven-day expiry |

## Session authority is not another credential

`auth_member_grants` binds a browser token to exact account Memberships;
`auth_member_grant_routes` records its independently aged personal or SSO proofs.
These rows are non-secret authorization state, not additional bearer credentials.
Reading memberships or switching accounts does not create proof. SSO step-up rotates
the browser token and preserves surviving proofs with their original deadlines;
it cannot renew personal mailbox or local-MFA proof. Authorized workspace creation
adds only its new owner Membership to the exact personally proved browser.

Member revocation deletes that Membership's grants. Provider or identity retirement
removes only its proof routes. Other independently proved access survives, although
affected sockets disconnect to refresh their authority. Personal sign-out/session
revocation and administrator/support MFA reset delete whole browser tokens.
Re-enabling a disabled account can restore still-valid proof; re-enabling a provider
does not recreate retired routes.

## Credentials that are NOT token tables

The inbound **SCIM bearer** (`ems-`) lives as a hashed column on
`Emisar.SSO.IdentityProvider`, not its own table — it's one secret per
configured IdP, rotated as part of that provider's config, and verified at the
SCIM boundary by `Emisar.SSO.authenticate_scim_token/1`.

Account invitation digests live on their pending membership row because the
membership owns the acceptance, rotation, address binding, and expiry as one
lifecycle.

A sign-in email change leaves the current address unchanged until the requesting
browser proves the new mailbox. Its pending proof binds the MFA enrollment that
authorized it; completion also needs the browser nonce and a live personal session.
Refreshing the page loses the nonce and requires restarting; the old address
remains usable. An abandoned proof stays inert until replaced or expired.

## Changelog

- 2026-09-23: new-address proof binds only the MFA enrollment and has no explicit
  cancel; replacement and expiry retire an abandoned proof.

- 2026-09-23: distinguished frozen Member grants and independent proof deadlines
  from bearer credentials, local revocation and whole-browser logout.

- 2026-09-22: documented session-bound new-address proof and corrected the Auth
  token table name against its current schema.

- 2026-08-26: moved verbatim from the compiled documentation-only module
  `Emisar.Tokens` (deleted — a zero-behavior BEAM module is not the home for
  repository knowledge).

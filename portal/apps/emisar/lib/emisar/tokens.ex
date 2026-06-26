defmodule Emisar.Tokens do
  @moduledoc """
  The token map — the one place to understand every bearer credential emisar
  mints, and which context owns it.

  There is deliberately **no** single tokens table: each credential has its own
  table and a single owning context that mints / verifies / revokes it. A SIEM
  log-shipping token is not an LLM-bridge key is not a runner session — keeping
  them apart keeps each lifecycle (and its abuse surface) reviewable in isolation.
  This module documents the split; it holds no logic. All secret generation,
  hashing, and constant-time comparison go through `Emisar.Crypto` — the single
  crypto-review surface — never inline in a context.

  ## The credentials

  | Credential | Table | Prefix | Owner | Mint | Verify | Revoke |
  |---|---|---|---|---|---|---|
  | MCP / LLM-bridge key & SIEM audit-export token (split by `kind`) | `api_keys` | `emk-` | `Emisar.ApiKeys` | `create_key/2`, `mint_quick_key/1` | `peek_api_key_by_secret/1` | `revoke_api_key/2` |
  | OAuth access / refresh token & auth code | `oauth_tokens`, `oauth_authorization_codes` | `emo-` / `emor-` / `emoc-` | `Emisar.OAuth` | `issue_code/3` → `exchange_code/1`, `refresh/1` | `resolve_access_token/1` | expiry sweeps (`delete_expired_authorization_codes/1`, `delete_unused_clients/1`) |
  | Runner enrollment key | `runner_auth_keys` | `rk-` | `Emisar.Runners` | `create_auth_key/2` | `peek_auth_key_by_secret/1` | `revoke_auth_key/2` |
  | Runner session token | `runner_tokens` | `rnrtok-` | `Emisar.Runners` | `mint_runner_token/2` | `verify_runner_token/1` | revoked with its enrollment key / runner (`Runners.Token.Changeset.revoke/1`) |
  | User session, magic-link, email-confirm | `user_tokens` | binary (unprefixed) | `Emisar.Auth` | `create_session_token!/5`, `issue_magic_link/2`, `deliver_confirmation_instructions/1` | `fetch_user_and_token_by_session_token/1`, `verify_magic_link/4` | `delete_session_token/1`, `revoke_session/2`, `delete_all_session_tokens/1` |

  ## The one credential that is NOT a token table

  The inbound **SCIM bearer** (`ems-`) lives as a hashed column on
  `Emisar.SSO.IdentityProvider`, not its own table — it's one secret per
  configured IdP, rotated as part of that provider's config, and verified at the
  SCIM boundary by `Emisar.SSO.authenticate_scim_token/1`.
  """
end

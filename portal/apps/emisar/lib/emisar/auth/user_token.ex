defmodule Emisar.Auth.UserToken do
  @moduledoc """
  Session and emailed-code tokens. Each row belongs to exactly one workspace
  Member (`account_id` + `membership_id`); a `sign_up` code alone belongs to
  none, because the workspace it creates does not exist yet
  (`auth_user_tokens_owner_check`). Stored hashed — the raw token is only ever
  returned to the caller at creation time (`Emisar.Crypto.session_token/0` /
  `magic_link_token/0`). One table for every token type: `context`
  disambiguates semantics, and `UserToken.Query.not_expired/2` owns each
  context's validity window.
  """
  use Emisar, :schema

  schema "auth_user_tokens" do
    field :token, :binary, redact: true
    field :context, :string
    field :sent_to, :string
    field :metadata, :map, default: %{}
    # Online-guess budget for typable emailed codes. nil for session tokens.
    field :remaining_attempts, :integer
    # How the session was authenticated — carried onto %Auth.Subject{} and
    # stamped on every audit row (provenance). `mfa_verified_at` is the generic
    # assurance present at authentication time: local TOTP for a magic-link
    # session, IdP assurance for SSO. `mfa_enrollment_verified_at` is separate
    # because an SSO session may later prove Emisar TOTP; it stores the exact
    # local enrollment epoch this session proved.
    field :auth_method, Ecto.Enum, values: [:magic_link, :sso]
    field :mfa_verified_at, :utc_datetime_usec
    field :mfa_enrollment_verified_at, :utc_datetime_usec
    field :local_mfa_expires_at, :utc_datetime_usec
    # The route an `:sso` session proved, frozen at sign-in: the session holds
    # only while its identity still carries this subject at this issuer.
    field :sso_issuer, :string
    field :sso_provider_identifier, :string
    # Digest of the random id of the browser that minted this session, so
    # signing out of that browser ends every session it minted, in every
    # workspace, including one its final cookie never held.
    field :browser_digest, :binary, redact: true

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    belongs_to :user_identity, Emisar.SSO.UserIdentity, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end

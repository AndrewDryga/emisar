defmodule Emisar.Auth.UserToken do
  @moduledoc """
  Long-lived (session) + ephemeral (magic link / reset / confirm) user
  tokens. Stored hashed — the raw token is only ever returned to the
  caller at creation time (`Emisar.Crypto.session_token/0` /
  `email_token/0`). One table for every token type: `context`
  disambiguates semantics, and `UserToken.Query.not_expired/2` owns
  each context's validity window.
  """
  use Emisar, :schema

  schema "auth_user_tokens" do
    field :token, :binary, redact: true
    field :context, :string
    field :sent_to, :string
    field :metadata, :map, default: %{}
    # Online-guess budget for typable magic-link and credential-step-up codes.
    # nil for opaque email/session tokens.
    field :remaining_attempts, :integer
    # How the session was authenticated — carried onto %Auth.Subject{} and
    # stamped on every audit row (provenance). `auth_method` is the method;
    # `mfa_verified_at` records WHEN this session proved a second factor, nil for
    # never (kept separate so "SSO + enforced TOTP" is expressible). Set only at
    # mint and never updated, on purpose: it is evidence about one sign-in, so
    # `Auth.session_mfa_verified?/2` binds it to the enrollment it proved rather
    # than the row moving under it. `user_identity` is :sso.
    field :auth_method, Ecto.Enum, values: [:magic_link, :sso]
    field :mfa_verified_at, :utc_datetime_usec

    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :user_identity, Emisar.SSO.UserIdentity, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end

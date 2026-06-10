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

  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]

    timestamps(updated_at: false)
  end
end

defmodule Emisar.OAuth.AuthorizationCode do
  @moduledoc """
  A single-use, short-lived (~60s) authorization code bound to the
  consenting operator's membership + a PKCE challenge. Exchanged once at
  the token endpoint for access + refresh tokens.
  """
  use Emisar, :schema

  schema "oauth_authz_codes" do
    field :code_hash, :binary, redact: true
    field :redirect_uri, :string
    field :code_challenge, :string
    field :code_challenge_method, :string, default: "S256"
    field :scope, :string
    field :resource, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    belongs_to :client, Emisar.OAuth.Client
    belongs_to :account, Emisar.Accounts.Account
    belongs_to :membership, Emisar.Accounts.Membership
    belongs_to :api_key, Emisar.ApiKeys.ApiKey

    timestamps(type: :utc_datetime_usec)
  end
end

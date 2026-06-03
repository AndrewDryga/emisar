defmodule Emisar.OAuth.Token do
  @moduledoc """
  An issued OAuth access token (with an optional rotating refresh token).
  Backed by an api_keys row: the MCP auth path resolves a presented
  access token to its backing key and reuses the existing scoping +
  attribution logic unchanged.
  """
  use Emisar, :schema

  schema "oauth_tokens" do
    field :access_token_hash, :binary, redact: true
    field :refresh_token_hash, :binary, redact: true
    field :scope, :string
    field :resource, :string
    field :access_expires_at, :utc_datetime_usec
    field :refresh_expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :client, Emisar.OAuth.Client
    belongs_to :account, Emisar.Accounts.Account
    belongs_to :membership, Emisar.Accounts.Membership
    belongs_to :api_key, Emisar.ApiKeys.ApiKey

    timestamps(type: :utc_datetime_usec)
  end
end

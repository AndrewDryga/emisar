defmodule Emisar.OAuth.Client do
  @moduledoc """
  A dynamically-registered OAuth client (RFC 7591) — typically Claude.ai
  or ChatGPT registering themselves to connect to the MCP server. The
  record is account-agnostic; the per-user binding happens at /authorize
  when a logged-in operator consents.
  """
  use Emisar, :schema

  schema "oauth_clients" do
    field :client_name, :string
    field :redirect_uris, {:array, :string}, default: []
    field :grant_types, {:array, :string}, default: []
    field :response_types, {:array, :string}, default: []
    field :scope, :string
    field :metadata, :map, default: %{}
    field :last_authorized_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end

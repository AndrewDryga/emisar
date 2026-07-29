defmodule Emisar.OAuth.Client do
  @moduledoc """
  An OAuth client — typically Claude.ai or ChatGPT connecting to the MCP
  server. The record is account-agnostic; the per-user binding happens at
  /authorize when a logged-in operator consents.

  Two registration mechanisms land here. A Client ID Metadata Document client
  identifies itself by the HTTPS URL its metadata is published at, kept in
  `client_id_metadata_url` and refreshed from that document on each
  authorization. A legacy Dynamic Client Registration client self-registers
  once and is identified by this row's own id, leaving that field null.
  """
  use Emisar, :schema

  schema "oauth_clients" do
    field :client_id_metadata_url, :string
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

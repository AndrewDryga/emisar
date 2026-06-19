defmodule Emisar.Repo.Migrations.OauthMcp do
  @moduledoc """
  OAuth 2.1 authorization-server tables so remote MCP clients
  (Claude.ai, ChatGPT) can connect via their connector UIs, which only
  speak OAuth — no static-bearer field. Three tables:

    * oauth_clients      — Dynamic Client Registration (RFC 7591) records
    * oauth_authz_codes  — short-lived authorization codes (PKCE)
    * oauth_tokens       — issued access + refresh tokens

  Every issued token is backed by an api_keys row (created at consent),
  so the existing MCP auth + scoping logic is reused unchanged: an OAuth
  access token resolves to its backing key.
  """
  use Ecto.Migration

  def change do
    # -- Dynamically-registered clients (Claude/ChatGPT) ---------------
    # Account-agnostic: a client registers anonymously; the per-user
    # binding happens at /authorize when a logged-in operator consents.
    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_name, :string
      add :redirect_uris, {:array, :string}, null: false, default: []
      add :grant_types, {:array, :string}, null: false, default: []
      add :response_types, {:array, :string}, null: false, default: []
      add :token_endpoint_auth_method, :string, null: false, default: "none"
      # Only set for confidential clients; public clients (PKCE) leave nil.
      add :client_secret_hash, :binary
      add :scope, :string
      add :metadata, :map, null: false, default: %{}
      # Last time a logged-in operator completed consent on this client; nil for
      # a registration that never authorized. The daily sweep prunes long-stale
      # never-authorized registrations.
      add :last_authorized_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # -- Authorization codes (single-use, ~60s, PKCE-bound) ------------
    create table(:oauth_authz_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code_hash, :binary, null: false

      add :client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :membership_id, references(:memberships, type: :binary_id, on_delete: :delete_all),
        null: false

      # Backing key minted at consent; the eventual token resolves to it.
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :code_challenge_method, :string, null: false, default: "S256"
      add :scope, :string
      add :resource, :string
      add :expires_at, :utc_datetime_usec, null: false
      add :used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_authz_codes, [:code_hash])

    # -- Issued tokens (access + rotating refresh) --------------------
    create table(:oauth_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :access_token_hash, :binary, null: false
      add :refresh_token_hash, :binary

      add :client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :membership_id, references(:memberships, type: :binary_id, on_delete: :delete_all),
        null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :delete_all),
        null: false

      add :scope, :string
      add :resource, :string
      add :access_expires_at, :utc_datetime_usec, null: false
      add :refresh_expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_tokens, [:access_token_hash])
    create unique_index(:oauth_tokens, [:refresh_token_hash])
    create index(:oauth_tokens, [:client_id])
    create index(:oauth_tokens, [:api_key_id])
  end
end

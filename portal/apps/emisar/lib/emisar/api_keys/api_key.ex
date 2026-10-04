defmodule Emisar.ApiKeys.ApiKey do
  @moduledoc """
  An API key for programmatic access. Authenticates MCP tool callers
  (Claude, Cursor, custom runners) and SIEM audit-export tokens. The key is
  identity + expiry + audit attribution only — it carries NO per-key
  authorization scope. What it may do is decided by account Policy + approval;
  which runners it may see and reach is the explicit runner access of the member
  it acts as — the operator who minted it, or a service account — resolved from
  `created_by_membership` at call time. `kind`
  is the sole capability discriminator: `:mcp` reaches the MCP tool surface,
  `:audit_export` the read-only `/api/audit` stream.
  """
  use Emisar, :schema

  schema "api_keys" do
    field :name, :string
    field :description, :string

    field :key_prefix, :string
    field :key_hash, :binary, redact: true

    # What this key IS — and its ONLY capability gate. `:mcp` is an LLM-bridge
    # key (the agents page); `:audit_export` is a read-only SIEM log-shipping
    # token (the audit page). Drives which list a key appears on, whether it
    # gets the default short expiry (export tokens don't — that would break log
    # shipping), and which endpoints it authenticates to (MCP vs `/api/audit`).
    field :kind, Ecto.Enum, values: [:mcp, :audit_export], default: :mcp

    field :expires_at, :utc_datetime_usec
    field :auto_rotation_supported, :boolean, default: false
    field :rotation_requested_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # Latest MCP clientInfo this key reported at `initialize` — snapshotted
    # onto each run dispatched afterward so the UI can name the client.
    field :last_client_info, :map, default: %{}

    # Stable across secret rotation. MCP operation recovery is owned by this
    # lineage rather than one short-lived bearer row.
    field :credential_lineage_id, Ecto.UUID

    # Set when the Agents page auto-mints this key for the snippet.
    # Cleared the moment an LLM successfully authenticates with it on
    # the MCP HTTP endpoint (at which point the key becomes a
    # permanent, visible "connected client"). While this is non-nil
    # AND last_used_at is nil, the key is tentative: invisible in UI,
    # subject to ring eviction beyond the per-account cap.
    field :auto_generated_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :revoked_by_membership, Emisar.Accounts.Membership
    # Installed successor — non-nil marks this key superseded
    # and makes retries of the same client-prepared proposal idempotent.
    belongs_to :rotated_to, Emisar.ApiKeys.ApiKey, where: [deleted_at: nil]
    # The rotation back-link: the key this one was minted to replace. Set at
    # rotation (operator or auto) — never from user input. First use of this
    # key proves the client swapped, so the replaced chain is retired then.
    belongs_to :replaces, Emisar.ApiKeys.ApiKey, where: [deleted_at: nil]
    # The member this key acts as: whoever minted it for themselves, or the
    # service account it was minted for. MCP dispatch resolves this member's
    # runner scope at call time, so narrowing that member shrinks every key
    # acting as them. Historical rows may be nil because the FK uses
    # `on_delete: :nilify_all`, but an unbound key is never usable.
    belongs_to :created_by_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]
    # The person who received this key when it acts as another member: a
    # service account's key, or a successor someone rotated for a teammate.
    # Nil when the key's own member issued it, or once staff erase the issuer.
    # Never cast, and it outlives the mint's audit row, so a long-lived
    # credential keeps naming its human — and that human's approvals count as
    # self-approvals of the requests it makes.
    belongs_to :issued_by_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]

    timestamps()
  end

  @doc """
  True when the key is auto-generated AND has never been used. Drives
  UI visibility (hidden) and ring eviction (only auto-unused keys get
  evicted; once an LLM has authed with a key, it stays).
  """
  def auto_unused?(%__MODULE__{auto_generated_at: nil}), do: false
  def auto_unused?(%__MODULE__{last_used_at: ts}) when not is_nil(ts), do: false
  def auto_unused?(%__MODULE__{}), do: true
end

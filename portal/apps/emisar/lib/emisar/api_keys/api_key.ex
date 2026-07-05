defmodule Emisar.ApiKeys.ApiKey do
  @moduledoc """
  An API key for programmatic access. Authenticates MCP tool callers
  (Claude, Cursor, custom runners) and SIEM audit-export tokens. The key is
  identity + expiry + audit attribution only — it carries NO per-key
  authorization scope. What it may do is decided by account Policy + approval;
  which runners it may see and reach is the minting operator's own runner scope
  (`created_by_membership`'s `UserRunnerScope`), resolved at call time. `kind`
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
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # Latest MCP clientInfo this key reported at `initialize` — snapshotted
    # onto each run dispatched afterward so the UI can name the client.
    field :last_client_info, :map, default: %{}

    # Set when the Agents page auto-mints this key for the snippet.
    # Cleared the moment an LLM successfully authenticates with it on
    # the MCP HTTP endpoint (at which point the key becomes a
    # permanent, visible "connected client"). While this is non-nil
    # AND last_used_at is nil, the key is tentative: invisible in UI,
    # subject to ring eviction beyond the per-account cap.
    field :auto_generated_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :created_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :revoked_by, Emisar.Users.User, where: [deleted_at: nil]
    # Successor minted by auto-rotation — non-nil marks this key superseded
    # and is the at-most-once guard for response-carried rotation.
    belongs_to :rotated_to, Emisar.ApiKeys.ApiKey, where: [deleted_at: nil]
    # The rotation back-link: the key this one was minted to replace. Set at
    # rotation (operator or auto) — never from user input. First use of this
    # key proves the client swapped, so the replaced chain is retired then.
    belongs_to :replaces, Emisar.ApiKeys.ApiKey, where: [deleted_at: nil]
    # Membership of the user who minted this key. MCP dispatch resolves
    # this membership's per-user runner scope at call-time so revoking
    # the operator's scope shrinks every key they ever issued. Nilable —
    # the FK is `on_delete: :nilify_all` so a removed-and-rejoined
    # operator's old keys outlive the membership row.
    belongs_to :created_by_membership, Emisar.Accounts.Membership, where: [deleted_at: nil]

    timestamps()
  end

  def usable?(%__MODULE__{revoked_at: nil, deleted_at: nil, expires_at: nil}), do: true

  def usable?(%__MODULE__{revoked_at: nil, deleted_at: nil, expires_at: exp}),
    do: DateTime.compare(DateTime.utc_now(), exp) == :lt

  def usable?(_), do: false

  @doc """
  True when the key is auto-generated AND has never been used. Drives
  UI visibility (hidden) and ring eviction (only auto-unused keys get
  evicted; once an LLM has authed with a key, it stays).
  """
  def auto_unused?(%__MODULE__{auto_generated_at: nil}), do: false
  def auto_unused?(%__MODULE__{last_used_at: ts}) when not is_nil(ts), do: false
  def auto_unused?(%__MODULE__{}), do: true
end

defmodule Emisar.ApiKeys.ApiKey do
  @moduledoc """
  An API key for programmatic access. Authenticates MCP tool callers
  (Claude, Cursor, custom runners). `runner_filter` restricts which
  runners a key may target; empty means "all runners in this account."
  """
  use Emisar, :schema

  schema "api_keys" do
    field :name, :string
    field :description, :string

    field :key_prefix, :string
    field :key_hash, :binary, redact: true

    field :runner_filter, {:array, :string}, default: []
    field :runner_group_filter, {:array, :string}, default: []
    field :scopes, {:array, :string}, default: []

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

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

    # What this key IS, kept explicit rather than inferred from `scopes`:
    # `:mcp` is an LLM-bridge key (the agents page); `:audit_export` is a
    # read-only SIEM log-shipping token (the audit page). Drives which list a
    # key appears on and whether it gets the default short expiry (export
    # tokens don't — that would break log shipping). `scopes` still carries the
    # capability (`actions:*` vs `audit:read`); `kind` is the type.
    field :kind, Ecto.Enum, values: [:mcp, :audit_export], default: :mcp

    field :runner_filter, {:array, :string}, default: []
    field :runner_group_filter, {:array, :string}, default: []
    field :scopes, {:array, :string}, default: []
    # Per-action allow-list. Empty = any action (the default); non-empty
    # restricts dispatch to exactly these action_ids — enforced in the domain
    # dispatch path (`Runs`) on top of the runner scope, so a leaked key can't run
    # actions the operator never granted it even if the MCP boundary is bypassed.
    field :action_scope, {:array, :string}, default: []

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
  Whether this key may dispatch `action_id`. An empty `action_scope` means any
  action (the default + every pre-existing key); a non-empty list is an
  allow-list — only those action_ids may run. Enforced in the domain dispatch
  path (`Runs`) alongside the runner-scope checks, plus a fast-fail at MCP.
  """
  def action_allowed?(%__MODULE__{action_scope: scope}, _action_id) when scope in [nil, []],
    do: true

  def action_allowed?(%__MODULE__{action_scope: scope}, action_id), do: action_id in scope

  @doc """
  Whether this key may dispatch to a runner (by its id + group). Empty filters
  mean any runner; otherwise the runner must be named in `runner_filter` or its
  group in `runner_group_filter`. Takes the runner's id + group (not the struct)
  so the schema stays context-pure. Enforced at the domain dispatch boundary.
  """
  def runner_allowed?(
        %__MODULE__{runner_filter: [], runner_group_filter: []},
        _runner_id,
        _group
      ),
      do: true

  def runner_allowed?(%__MODULE__{} = key, runner_id, runner_group),
    do: runner_id in (key.runner_filter || []) or runner_group in (key.runner_group_filter || [])

  @doc """
  True when the key is auto-generated AND has never been used. Drives
  UI visibility (hidden) and ring eviction (only auto-unused keys get
  evicted; once an LLM has authed with a key, it stays).
  """
  def auto_unused?(%__MODULE__{auto_generated_at: nil}), do: false
  def auto_unused?(%__MODULE__{last_used_at: ts}) when not is_nil(ts), do: false
  def auto_unused?(%__MODULE__{}), do: true

  @doc """
  Whether the key carries `scope` in its `scopes` grant-list — the broad
  capability scopes (`actions:read`, `actions:execute`, `audit:read`, …) the MCP
  and audit-export controllers gate on, distinct from the per-action
  `action_scope` that `action_allowed?/2` checks.
  """
  def has_scope?(%__MODULE__{scopes: scopes}, scope), do: scope in (scopes || [])
end

defmodule Emisar.Policies.Policy do
  @moduledoc """
  A policy bundle scoped to an account, a single runner, or a runner group.
  Each `(account_id, scope_type, scope_value)` has at most one live row
  (partial unique index). Dispatch resolves the MOST SPECIFIC scope (runner >
  group > account) and evaluates it wholesale — a scoped policy fully replaces
  the account default for that runner/group, it doesn't layer on top. The
  runner never sees any of it; cloud evaluates the rules before `run_action`.
  """
  use Emisar, :schema

  schema "policies" do
    # Default kept empty; concrete v2 defaults live on `Policies.@default_rules`
    # and are stamped in by `seed_policy/3` so the schema doesn't drift
    # if the policy shape changes.
    field :rules, :map, default: %{}
    # Bumped on every accepted rules edit (the upsert's conflict CASE in
    # `Policy.Query.rules_upsert_conflict/0`) so the audit trail can pin
    # "run 123 was decided under policy v5" even after the rules map is
    # later modified.
    field :vsn, :integer, default: 1

    # Scope this bundle applies to. `scope_value` is the runner_id for
    # `:runner`, the group name for `:group`, and "" for the account default.
    field :scope_type, Ecto.Enum, values: [:account, :runner, :group], default: :account
    field :scope_value, :string, default: ""

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :updated_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end

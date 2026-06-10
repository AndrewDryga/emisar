defmodule Emisar.Policies.Policy do
  @moduledoc """
  The single policy bundle for an account. The DB enforces one row per
  `account_id` via a unique index; there is no list view, no draft, no
  versioning — operators edit this one row in place. The runner doesn't
  see it; cloud evaluates the rules before sending `run_action`.
  """
  use Emisar, :schema

  schema "policies" do
    # Default kept empty; concrete v2 defaults live on `Policies.@default_rules`
    # and are stamped in by `seed_policy/3` so the schema doesn't drift
    # if the policy shape changes.
    field :rules, :map, default: %{}
    # Bumped by `Changeset.update_rules/2` on every accepted edit so the
    # audit trail can pin "run 123 was decided under policy v5" even
    # after the rules map is later modified.
    field :vsn, :integer, default: 1
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :updated_by, Emisar.Accounts.User, where: [deleted_at: nil]

    timestamps()
  end
end

defmodule Emisar.Fixtures.Policies do
  @moduledoc """
  Policy test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Policies.create_policy/1`.
  """

  alias Emisar.{Fixtures, Policies, Repo}

  @doc """
  Seeds or replaces the account's policy. Defaults to "allow
  everything". Override `:rules` to test other shapes.

  Since there's exactly one policy per account, this either inserts on
  first call OR updates the existing row's rules — never creates a
  second row.
  """
  def create_policy(attrs \\ %{}) do
    attrs = Map.new(attrs)
    account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
    user_id = attrs[:created_by_id] || Fixtures.Users.create_user().id

    rules =
      attrs[:rules] ||
        %{
          "schema_version" => 2,
          "defaults" => %{
            "low" => "allow",
            "medium" => "allow",
            "high" => "allow",
            "critical" => "allow"
          },
          "overrides" => [],
          "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
        }

    rules = Map.put_new(rules, "approval", %{"min_approvals" => 1, "allow_self_approval" => true})

    changeset =
      Policies.Policy.Changeset.create(%{
        account_id: account_id,
        updated_by_id: user_id,
        rules: rules
      })

    {:ok, policy} =
      Repo.insert(changeset,
        on_conflict: Policies.Policy.Query.rules_upsert_conflict(),
        conflict_target:
          {:unsafe_fragment, "(account_id, scope_type, scope_value) WHERE deleted_at IS NULL"},
        returning: true
      )

    policy
  end
end

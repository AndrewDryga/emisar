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
          "overrides" => []
        }

    case Policies.peek_policy_for_account(account_id) do
      nil ->
        {:ok, _} = Policies.seed_policy(account_id, user_id, rules)
        Policies.peek_policy_for_account(account_id)

      policy ->
        {:ok, updated} =
          Repo.update(
            Policies.Policy.Changeset.update(policy, %{
              rules: rules,
              updated_by_id: user_id
            })
          )

        updated
    end
  end
end

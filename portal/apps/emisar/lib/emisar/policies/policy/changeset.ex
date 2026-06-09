defmodule Emisar.Policies.Policy.Changeset do
  use Emisar, :changeset
  alias Emisar.Policies.Policy

  @valid_sections ["schema_version", "defaults", "overrides"]
  @valid_tiers ~w(low medium high critical)
  @valid_decisions ~w(allow require_approval deny)

  @doc """
  Validation-only changeset for the policy editor form. Casts the
  assembled `rules` map and runs the same `validate_rules/1` checks as
  `create/1` + `update/1`, so the LiveView can back its form with a
  changeset and render the rules-level error inline (rose border + message)
  instead of a flash. Persists nothing; the real write goes through
  `Policies.save_rules/2`.
  """
  def form(rules) do
    %Policy{}
    |> cast(%{rules: rules}, [:rules])
    |> validate_rules()
  end

  def create(attrs) do
    %Policy{}
    |> cast(attrs, [:account_id, :rules, :updated_by_id])
    |> validate_required([:account_id, :rules])
    |> validate_rules()
    |> unique_constraint(:account_id)
  end

  def update(%Policy{} = policy, attrs) do
    policy
    |> cast(attrs, [:rules, :updated_by_id])
    |> validate_required([:rules])
    |> validate_rules()
    |> maybe_bump_vsn(policy)
  end

  # Bump the version whenever the rules map actually changes. Pure
  # cast (no rule change) shouldn't increment — protects against
  # touching `updated_by_id` alone bumping the audit-correlation
  # number without an actual decision-affecting edit.
  defp maybe_bump_vsn(changeset, %Policy{vsn: current, rules: existing_rules}) do
    case get_change(changeset, :rules) do
      nil -> changeset
      ^existing_rules -> changeset
      _new_rules -> put_change(changeset, :vsn, (current || 1) + 1)
    end
  end

  def delete(%Policy{} = policy) do
    change(policy, deleted_at: now())
  end

  defp validate_rules(changeset) do
    case get_change(changeset, :rules) do
      nil ->
        changeset

      rules when is_map(rules) ->
        with :ok <- check_sections(rules),
             :ok <- check_defaults(rules["defaults"]),
             :ok <- check_overrides(rules["overrides"]) do
          changeset
        else
          {:error, msg} -> add_error(changeset, :rules, msg)
        end

      _ ->
        add_error(changeset, :rules, "must be a JSON object")
    end
  end

  defp check_sections(rules) do
    case Map.keys(rules) -- @valid_sections do
      [] -> :ok
      extra -> {:error, "unknown rule sections: #{inspect(extra)}"}
    end
  end

  defp check_defaults(nil), do: :ok

  defp check_defaults(%{} = defaults) do
    bad_tiers = Map.keys(defaults) -- @valid_tiers
    bad_values = Map.values(defaults) |> Enum.reject(&(&1 in @valid_decisions))

    cond do
      bad_tiers != [] -> {:error, "unknown risk tiers: #{inspect(bad_tiers)}"}
      bad_values != [] -> {:error, "unknown decisions: #{inspect(bad_values)}"}
      true -> check_tier_monotonicity(defaults)
    end
  end

  defp check_defaults(_), do: {:error, "defaults must be a JSON object"}

  # Each tier in [low, medium, high, critical] must be at least as
  # restrictive as the one before it (rank: allow < require_approval
  # < deny). Lets us write `cassandra.drain` policies that can't
  # accidentally be more permissive than `cassandra.nodetool_status`.
  defp check_tier_monotonicity(defaults) do
    @valid_tiers
    |> Enum.map(&Map.get(defaults, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Emisar.Policies.decision_rank/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [a, b] -> a > b end)
    |> case do
      nil ->
        :ok

      _violation ->
        {:error,
         "higher-risk tiers must be at least as restrictive as lower-risk tiers " <>
           "(e.g. you can't set high=allow when medium=require_approval)"}
    end
  end

  defp check_overrides(nil), do: :ok

  defp check_overrides(overrides) when is_list(overrides) do
    Enum.reduce_while(overrides, :ok, fn ov, _ ->
      cond do
        not is_map(ov) ->
          {:halt, {:error, "each override must be a JSON object"}}

        Map.get(ov, "decision") not in @valid_decisions ->
          {:halt,
           {:error, "override decision must be one of #{Enum.join(@valid_decisions, ", ")}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check_overrides(_), do: {:error, "overrides must be a list"}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

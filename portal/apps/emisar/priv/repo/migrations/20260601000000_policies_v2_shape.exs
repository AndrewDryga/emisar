defmodule Emisar.Repo.Migrations.PoliciesV2Shape do
  @moduledoc """
  Convert `policies.rules` from the old shape
  `{"allow" => [...], "require_approval" => [...]}` to the v2 shape
  `{"schema_version" => 2, "defaults" => {tier => decision}, "overrides" => [...]}`.

  Old rules are inspected once and translated:

    * rules with an `action` field (action_glob) → emitted as an
      override with the section's decision.
    * rules with a `risk` or `max_risk` field but no `action` → folded
      into the tier defaults.
    * everything else → emit as override with action="*".

  Anything we can't classify falls back to the conservative default
  (low/medium allow, high require_approval, critical deny).
  """
  use Ecto.Migration

  @default_rules %{
    "schema_version" => 2,
    "defaults" => %{
      "low" => "allow",
      "medium" => "allow",
      "high" => "require_approval",
      "critical" => "deny"
    },
    "overrides" => []
  }

  def up do
    repo().query!("SELECT id, rules FROM policies WHERE deleted_at IS NULL", [])
    |> Map.get(:rows)
    |> Enum.each(fn [id, rules] ->
      new_rules = convert(rules)

      repo().query!("UPDATE policies SET rules = $1 WHERE id = $2", [new_rules, id])
    end)
  end

  def down do
    # one-way migration. The old shape is structurally different and
    # carries strictly less information than v2.
    :ok
  end

  defp convert(%{"schema_version" => 2} = rules), do: rules

  defp convert(rules) when is_map(rules) do
    allow_rules = List.wrap(rules["allow"])
    approval_rules = List.wrap(rules["require_approval"])

    overrides =
      Enum.map(allow_rules, &override_from_rule(&1, "allow")) ++
        Enum.map(approval_rules, &override_from_rule(&1, "require_approval"))

    defaults = derive_defaults(allow_rules, approval_rules)

    %{
      "schema_version" => 2,
      "defaults" => Map.merge(@default_rules["defaults"], defaults),
      "overrides" => Enum.reject(overrides, &is_nil/1)
    }
  end

  defp convert(_), do: @default_rules

  defp override_from_rule(%{"action" => action} = r, decision) when is_binary(action) and action != "" do
    %{
      "name" => r["name"] || "migrated",
      "action" => action,
      "decision" => decision
    }
  end

  defp override_from_rule(_, _), do: nil

  # Rules with no action but a risk constraint become tier defaults.
  defp derive_defaults(allow_rules, approval_rules) do
    Enum.reduce(allow_rules ++ approval_rules, %{}, fn rule, acc ->
      decision = if rule in allow_rules, do: "allow", else: "require_approval"
      apply_risk_to_defaults(rule, decision, acc)
    end)
  end

  defp apply_risk_to_defaults(%{"action" => a}, _decision, acc) when is_binary(a) and a != "",
    do: acc

  defp apply_risk_to_defaults(%{"max_risk" => max}, decision, acc) when is_binary(max) do
    Enum.reduce(tiers_up_to(max), acc, fn t, a -> Map.put(a, t, decision) end)
  end

  defp apply_risk_to_defaults(%{"risk" => exact}, decision, acc) when is_binary(exact) do
    Map.put(acc, exact, decision)
  end

  defp apply_risk_to_defaults(_, _, acc), do: acc

  defp tiers_up_to("low"), do: ~w(low)
  defp tiers_up_to("medium"), do: ~w(low medium)
  defp tiers_up_to("high"), do: ~w(low medium high)
  defp tiers_up_to("critical"), do: ~w(low medium high critical)
  defp tiers_up_to(_), do: []
end

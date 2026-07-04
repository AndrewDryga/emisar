defmodule Emisar.Billing.Entitlements do
  @moduledoc """
  Plan entitlements mirrored from the Paddle product's `custom_data`.

  Paid-plan limits live on the Paddle product (dashboard-editable, so a limit
  change or a brand-new plan needs no deploy). Subscription webhooks embed the
  full product per line item, so the extraction here reads its `custom_data`
  and validates it into the canonical map stored on `Subscription.entitlements`;
  the compiled `Billing.plans/0` map remains only the free tier, the per-field
  fallback for absent/invalid keys, and display copy.

  Recognized keys: `plan` (the plan slug), `runners_limit`, `members_limit`,
  `audit_retention_days` (integers, or `"unlimited"` for the limits), and the
  feature flags `features_sso_enabled?` / `features_scim_enabled?` (booleans —
  the key names match what's typed in the Paddle dashboard). Values typed into
  the dashboard arrive as strings, so `"100"`, `"true"`, and `"unlimited"` are
  normalized on the way in; anything unparseable (and any unknown key) is
  dropped rather than stored, so a dashboard typo degrades to the plan default
  instead of corrupting a read path.
  """

  @limit_keys ~w[runners_limit members_limit audit_retention_days]
  @feature_keys ~w[features_sso_enabled? features_scim_enabled? features_audit_export_enabled?]

  # Postgres timestamps cap around year 294276, so an absurd
  # audit_retention_days must not survive into retention arithmetic.
  @max_limit 1_000_000

  @doc """
  Extracts + validates entitlements from a Paddle subscription payload (a
  webhook `data` object or a live `retrieve_subscription/1` result). Returns
  the canonical map, or `nil` when the payload carries no product object at
  all — callers `put_present` it so stored entitlements are preserved when a
  lean payload omits the product.
  """
  def from_paddle_subscription(subscription_data) do
    case product_custom_data(subscription_data) do
      nil -> nil
      custom_data -> parse(custom_data)
    end
  end

  @doc """
  The plan slug from the product custom_data's `plan` key, or `nil` when
  absent or not a valid slug. This is what lets a plan created in the Paddle
  dashboard identify itself without a deployed price-id mapping.
  """
  def plan_slug(subscription_data), do: plan_slug_of_product(product(subscription_data))

  @doc "Same as `plan_slug/1` but for a bare product entity (a catalog listing entry)."
  def plan_slug_of_product(%{"custom_data" => %{"plan" => slug}}) when is_binary(slug),
    do: validate_slug(String.trim(slug))

  def plan_slug_of_product(_product), do: nil

  @doc "The embedded product's display name, or `nil` when the payload carries no product."
  def product_name(subscription_data) do
    case product(subscription_data) do
      %{"name" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc """
  Validates a raw custom_data map into the canonical entitlements map.
  Unknown keys and unparseable values are dropped; a non-map parses to `%{}`.
  """
  def parse(%{} = custom_data), do: custom_data |> Enum.flat_map(&normalized_entry/1) |> Map.new()
  def parse(_custom_data), do: %{}

  @doc """
  The entitlement limit stored under `key` — a non-negative integer,
  `:unlimited`, or `nil` when absent (the caller falls back to the compiled
  plan default).
  """
  def limit(%{} = entitlements, key) when key in @limit_keys do
    case entitlements[key] do
      "unlimited" -> :unlimited
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  @doc "The boolean feature entitlement under `key`, or `nil` when absent."
  def feature(%{} = entitlements, key) when key in @feature_keys do
    case entitlements[key] do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # The webhook embeds the full product per item and we bill a single line
  # item. `nil` (no product object — e.g. a lean API shape) is distinct from a
  # product whose custom_data is empty/null, which normalizes to %{}.
  defp product_custom_data(subscription_data) do
    case product(subscription_data) do
      nil -> nil
      product -> product["custom_data"] || %{}
    end
  end

  defp product(%{"items" => [%{"product" => %{} = product} | _]}), do: product
  defp product(_subscription_data), do: nil

  defp normalized_entry({key, raw}) when key in @limit_keys do
    case parse_limit(raw) do
      nil -> []
      value -> [{key, value}]
    end
  end

  defp normalized_entry({key, raw}) when key in @feature_keys do
    case parse_boolean(raw) do
      nil -> []
      value -> [{key, value}]
    end
  end

  defp normalized_entry(_entry), do: []

  defp parse_limit(value) when is_integer(value) and value in 0..@max_limit, do: value

  defp parse_limit(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {int, ""} when int in 0..@max_limit -> int
      _ -> parse_unlimited(trimmed)
    end
  end

  defp parse_limit(_value), do: nil

  defp parse_unlimited(value),
    do: if(String.downcase(value) == "unlimited", do: "unlimited", else: nil)

  defp parse_boolean(value) when is_boolean(value), do: value

  defp parse_boolean(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case normalized do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp parse_boolean(_value), do: nil

  defp validate_slug(slug), do: if(slug =~ ~r/^[a-z][a-z0-9_-]{0,31}$/, do: slug, else: nil)
end

defmodule Emisar.Billing.EntitlementsTest do
  use ExUnit.Case, async: true
  alias Emisar.Billing.Entitlements

  describe "from_paddle_subscription/1" do
    test "extracts + normalizes the first item's product custom_data" do
      custom_data = %{"runners_limit" => 100, "features_sso_enabled?" => true}

      assert Entitlements.from_paddle_subscription(product_data(custom_data)) ==
               %{"runners_limit" => 100, "features_sso_enabled?" => true}
    end

    test "a product with null custom_data normalizes to an empty map" do
      assert Entitlements.from_paddle_subscription(product_data(nil)) == %{}
    end

    test "nil when the payload carries no product object (lean API shape)" do
      lean = %{"items" => [%{"price" => %{"id" => "pri_1"}}]}

      assert Entitlements.from_paddle_subscription(lean) == nil
      assert Entitlements.from_paddle_subscription(%{}) == nil
    end
  end

  describe "plan_slug/1" do
    test "reads a valid slug from the product custom_data, trimming whitespace" do
      assert Entitlements.plan_slug(product_data(%{"plan" => "team"})) == "team"
      assert Entitlements.plan_slug(product_data(%{"plan" => " pro-2 "})) == "pro-2"
    end

    test "nil for an absent, non-string, or invalid slug" do
      assert Entitlements.plan_slug(product_data(%{})) == nil
      assert Entitlements.plan_slug(product_data(%{"plan" => 7})) == nil
      assert Entitlements.plan_slug(product_data(%{"plan" => "Team Plan!"})) == nil
      assert Entitlements.plan_slug(%{}) == nil
    end
  end

  describe "parse/1" do
    test "normalizes dashboard-typed strings to canonical values" do
      raw = %{
        "runners_limit" => "100",
        "members_limit" => "Unlimited",
        "audit_retention_days" => 90,
        "features_sso_enabled?" => "true",
        "features_scim_enabled?" => false
      }

      assert Entitlements.parse(raw) == %{
               "runners_limit" => 100,
               "members_limit" => "unlimited",
               "audit_retention_days" => 90,
               "features_sso_enabled?" => true,
               "features_scim_enabled?" => false
             }
    end

    test "drops unknown keys and unparseable or out-of-bound values" do
      raw = %{
        "runners_limit" => "lots",
        "members_limit" => -1,
        "audit_retention_days" => 10_000_000_000,
        "features_sso_enabled?" => "yes",
        "plan" => "team",
        "upgrade_description" => "marketing copy"
      }

      assert Entitlements.parse(raw) == %{}
    end

    test "a non-map parses to an empty map" do
      assert Entitlements.parse(nil) == %{}
      assert Entitlements.parse("garbage") == %{}
    end
  end

  describe "limit/2" do
    test "canonical values map to the integer or :unlimited; absent is nil" do
      assert Entitlements.limit(%{"runners_limit" => 5}, "runners_limit") == 5
      assert Entitlements.limit(%{"runners_limit" => "unlimited"}, "runners_limit") == :unlimited
      assert Entitlements.limit(%{}, "runners_limit") == nil
    end
  end

  describe "feature/2" do
    test "booleans pass through; absent is nil" do
      assert Entitlements.feature(%{"features_sso_enabled?" => false}, "features_sso_enabled?") ==
               false

      assert Entitlements.feature(%{"features_scim_enabled?" => true}, "features_scim_enabled?") ==
               true

      assert Entitlements.feature(%{}, "features_scim_enabled?") == nil
    end
  end

  defp product_data(custom_data),
    do: %{"items" => [%{"product" => %{"id" => "pro_1", "custom_data" => custom_data}}]}
end

defmodule Emisar.PoliciesAuditTest do
  use Emisar.DataCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Audit, Policies}

  describe "policy.updated audit payload" do
    setup do
      user = user_fixture()

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "X", slug: "x-#{System.unique_integer()}", plan: "free"},
          user
        )

      subject = subject_for(user, account)
      {:ok, policy} = Policies.fetch_policy(subject)
      %{user: user, account: account, subject: subject, policy: policy}
    end

    test "captures before/after snapshots", %{
      user: user,
      subject: subject,
      policy: policy
    } do
      new_rules = %{
        "schema_version" => 2,
        "defaults" => %{
          "low" => "allow",
          "medium" => "require_approval",
          "high" => "deny",
          "critical" => "deny"
        },
        "overrides" => [
          %{"name" => "allow-status", "action" => "cassandra.status", "decision" => "allow"}
        ]
      }

      {:ok, updated} = Policies.save_rules(new_rules, subject)

      {:ok, [event], _} =
        Audit.list_events(subject, filter: [event_type: ["policy.updated"]])

      assert event.actor_id == user.id
      assert is_map(event.payload)
      assert event.payload["before"]["schema_version"] == 2
      assert event.payload["after"]["defaults"]["medium"] == "require_approval"
      # vsn bumps on every rule mutation so operators can correlate
      # specific runs back to "the policy that was active when this
      # decision was made".
      assert event.payload["from_version"] == policy.vsn
      assert event.payload["to_version"] == policy.vsn + 1
      assert updated.vsn == policy.vsn + 1
    end

    test "diff identifies tier flips", %{subject: subject, policy: policy} do
      new_rules =
        Policies.default_rules()
        |> Map.update!("defaults", &Map.put(&1, "critical", "require_approval"))

      {:ok, _} = Policies.save_rules(new_rules, subject)

      {:ok, [event], _} =
        Audit.list_events(subject, filter: [event_type: ["policy.updated"]])

      assert event.payload["changes"]["defaults"]["critical"] ==
               %{"from" => "deny", "to" => "require_approval"}

      refute Map.has_key?(event.payload["changes"]["defaults"], "low")
    end

    test "diff identifies override add / remove / change", %{
      subject: subject,
      policy: policy
    } do
      starting =
        Policies.default_rules()
        |> Map.put("overrides", [
          %{"name" => "keep", "action" => "keep.me", "decision" => "allow"},
          %{"name" => "modify", "action" => "modify.me", "decision" => "allow"},
          %{"name" => "remove", "action" => "remove.me", "decision" => "deny"}
        ])

      {:ok, policy} = Policies.save_rules(starting, subject)

      next =
        Policies.default_rules()
        |> Map.put("overrides", [
          %{"name" => "keep", "action" => "keep.me", "decision" => "allow"},
          %{"name" => "modify", "action" => "modify.me", "decision" => "deny"},
          %{"name" => "add", "action" => "add.me", "decision" => "allow"}
        ])

      {:ok, _} = Policies.save_rules(next, subject)

      {:ok, events, _} =
        Audit.list_events(subject, filter: [event_type: ["policy.updated"]])

      latest = hd(events)
      changes = latest.payload["changes"]["overrides"]

      assert Enum.any?(changes["added"], &(&1["action"] == "add.me"))
      assert Enum.any?(changes["removed"], &(&1["action"] == "remove.me"))
      assert [%{"action" => "modify.me", "from" => from, "to" => to}] = changes["changed"]
      assert from["decision"] == "allow"
      assert to["decision"] == "deny"
    end
  end
end

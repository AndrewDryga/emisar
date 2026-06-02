defmodule EmisarWeb.AuditSummaryTest do
  @moduledoc """
  Audit-event summary helper unit tests. Verifies that each known event
  type produces a sensible chip list and that unknown / payload-less
  events fall through silently — so the UI never renders an empty
  summary strip with no content.

  Payload keys are tested as strings because that's what jsonb gives
  back on read; the helper also accepts atom keys to support test
  fixtures that build events without round-tripping through the DB.
  """
  use ExUnit.Case, async: true

  alias EmisarWeb.AuditSummary

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  describe "membership.role_changed" do
    test "renders from → to" do
      assert [{"change", "operator → admin"}] =
               AuditSummary.summary_pairs(
                 ev("membership.role_changed", %{"from" => "operator", "to" => "admin"})
               )
    end

    test "ignores no-op when from == to" do
      assert [] =
               AuditSummary.summary_pairs(
                 ev("membership.role_changed", %{"from" => "admin", "to" => "admin"})
               )
    end
  end

  describe "user.email_changed" do
    test "renders from → to" do
      assert [{"change", "old@example.com → new@example.com"}] =
               AuditSummary.summary_pairs(
                 ev("user.email_changed", %{
                   "from" => "old@example.com",
                   "to" => "new@example.com"
                 })
               )
    end
  end

  describe "user.signed_in" do
    test "shows method when present" do
      assert [{"via", "password"}] =
               AuditSummary.summary_pairs(ev("user.signed_in", %{"method" => "password"}))
    end

    test "drops to empty when method missing" do
      assert [] = AuditSummary.summary_pairs(ev("user.signed_in", %{}))
    end
  end

  describe "user.other_sessions_revoked" do
    test "renders the count" do
      assert [{"count", "3"}] =
               AuditSummary.summary_pairs(ev("user.other_sessions_revoked", %{"count" => 3}))
    end

    test "ignores zero" do
      assert [] = AuditSummary.summary_pairs(ev("user.other_sessions_revoked", %{"count" => 0}))
    end
  end

  describe "account.require_mfa_set" do
    test "renders 'enforced' for true" do
      assert [{"MFA", "enforced"}] =
               AuditSummary.summary_pairs(ev("account.require_mfa_set", %{"require_mfa" => true}))
    end

    test "renders 'off' for false" do
      assert [{"MFA", "off"}] =
               AuditSummary.summary_pairs(
                 ev("account.require_mfa_set", %{"require_mfa" => false})
               )
    end
  end

  describe "runbook.updated" do
    test "renders v1 → v2 for new-version events" do
      assert [{"version", "v1 → v2"}] =
               AuditSummary.summary_pairs(
                 ev("runbook.updated", %{"from_version" => 1, "to_version" => 2})
               )
    end
  end

  describe "action_run.success" do
    test "renders sub-second duration in ms" do
      assert [{"duration_ms", "850ms"}] =
               AuditSummary.summary_pairs(ev("action_run.success", %{"duration_ms" => 850}))
    end

    test "renders seconds when over 1s" do
      assert [{"duration_ms", "12.3s"}] =
               AuditSummary.summary_pairs(ev("action_run.success", %{"duration_ms" => 12_345}))
    end

    test "renders minutes when over 1m" do
      assert [{"duration_ms", "5m 30s"}] =
               AuditSummary.summary_pairs(
                 ev("action_run.success", %{"duration_ms" => 5 * 60_000 + 30_000})
               )
    end
  end

  describe "policy.updated" do
    test "tallies override changes" do
      pairs =
        AuditSummary.summary_pairs(
          ev("policy.updated", %{
            "changes" => %{
              "defaults" => %{"critical" => %{"from" => "deny", "to" => "require_approval"}},
              "overrides" => %{
                "added" => [%{"action" => "a"}, %{"action" => "b"}],
                "removed" => [%{"action" => "c"}],
                "changed" => []
              }
            }
          })
        )

      assert pairs == [
               {"tier defaults", "1"},
               {"+overrides", "2"},
               {"-overrides", "1"}
             ]
    end

    test "empty changes produce no chips" do
      assert [] = AuditSummary.summary_pairs(ev("policy.updated", %{"changes" => %{}}))
    end
  end

  describe "graceful fallthrough" do
    test "unknown event types produce no chips" do
      assert [] = AuditSummary.summary_pairs(ev("totally.made_up_event", %{"foo" => "bar"}))
    end

    test "nil payload is safe" do
      assert [] = AuditSummary.summary_pairs(%{event_type: "user.signed_in", payload: nil})
    end

    test "accepts atom keys (test fixtures)" do
      assert [{"via", "password"}] =
               AuditSummary.summary_pairs(ev("user.signed_in", %{method: "password"}))
    end
  end
end

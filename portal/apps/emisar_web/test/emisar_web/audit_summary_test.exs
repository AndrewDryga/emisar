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
      assert [{"via", "magic_link"}] =
               AuditSummary.summary_pairs(ev("user.signed_in", %{"method" => "magic_link"}))
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

    test "a runner-scoped edit leads with a scope chip" do
      pairs =
        AuditSummary.summary_pairs(
          ev("policy.updated", %{
            "scope_type" => "runner",
            "scope_value" => "runner-1",
            "changes" => %{"defaults" => %{"low" => %{"from" => "allow", "to" => "deny"}}}
          })
        )

      assert pairs == [{"scope", "runner: runner-1"}, {"tier defaults", "1"}]
    end

    test "an account-scoped edit gets no scope chip" do
      pairs =
        AuditSummary.summary_pairs(
          ev("policy.updated", %{
            "scope_type" => "account",
            "scope_value" => "",
            "changes" => %{"defaults" => %{"low" => %{"from" => "allow", "to" => "deny"}}}
          })
        )

      assert pairs == [{"tier defaults", "1"}]
    end
  end

  describe "policy.scope_deleted" do
    test "names the removed override's scope" do
      assert [{"scope", "group: db"}] =
               AuditSummary.summary_pairs(
                 ev("policy.scope_deleted", %{"scope_type" => "group", "scope_value" => "db"})
               )
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
      assert [{"via", "magic_link"}] =
               AuditSummary.summary_pairs(ev("user.signed_in", %{method: "magic_link"}))
    end
  end

  describe "session.account_switched" do
    test "shows the role in the switched-to account" do
      assert [{"role", "admin"}] =
               AuditSummary.summary_pairs(ev("session.account_switched", %{"role" => "admin"}))
    end

    test "no chip when role is absent" do
      assert [] = AuditSummary.summary_pairs(ev("session.account_switched", %{}))
    end
  end

  describe "remaining event types (table)" do
    test "each renders its notable fact" do
      cases = [
        {"account.created", %{"plan" => "team", "slug" => "acme"},
         [{"plan", "team"}, {"slug", "acme"}]},
        {"account.updated", %{"name" => "Acme", "slug" => nil}, [{"name", "Acme"}]},
        {"membership.removed", %{"role" => "operator"}, [{"role", "operator"}]},
        {"membership.runner_scopes_changed", %{"scope_count" => 3}, [{"scopes", "3"}]},
        {"membership.runner_scopes_changed", %{"scope_count" => 0},
         [{"scopes", "cleared (all runners)"}]},
        {"membership.invitation_accepted", %{"role" => "admin"}, [{"role", "admin"}]},
        {"user.invitation_accepted", %{"role" => "viewer"}, [{"role", "viewer"}]},
        {"user.invited", %{"role" => "operator"}, [{"role", "operator"}]},
        {"user.sign_in_failed", %{"reason" => "bad_password"}, [{"reason", "bad_password"}]},
        {"user.mfa_failed", %{"reason" => "invalid_otp"}, [{"reason", "invalid_otp"}]},
        {"user.mfa_recovery_code_used", %{"remaining" => 7}, [{"codes left", "7"}]},
        {"user.session_revoked", %{"anything" => "x"}, []},
        {"user.profile_updated", %{"full_name" => "Ada"}, [{"full name", "Ada"}]},
        {"user.profile_updated", %{"full_name" => ""}, []},
        {"user.updated_by_admin", %{"full_name" => "Bob"}, [{"full name", "Bob"}]},
        {"runner.registered", %{"group" => "prod", "hostname" => "host-1"},
         [{"group", "prod"}, {"hostname", "host-1"}]},
        {"runner.disconnected", %{"reason" => "drain"}, [{"reason", "drain"}]},
        {"auth_key.created", %{"group" => "prod", "reusable" => true},
         [{"group", "prod"}, {"reusable", "yes"}]},
        {"auth_key.created", %{"reusable" => false}, [{"reusable", "no"}]},
        {"auth_key.revoked", %{"prefix" => "eak-1234"}, [{"prefix", "eak-1234"}]},
        {"auth_key.bound", %{"prefix" => "eak-1234", "auto" => true},
         [{"prefix", "eak-1234"}, {"source", "auto-mint"}]},
        {"auth_key.bound", %{"prefix" => "eak-1234"}, [{"prefix", "eak-1234"}]},
        {"api_key.created", %{"prefix" => "emk-1234", "scopes" => ["runs", "audit"]},
         [{"prefix", "emk-1234"}, {"scopes", "runs, audit"}]},
        {"api_key.created", %{"prefix" => "emk-1234", "scopes" => []}, [{"prefix", "emk-1234"}]},
        {"api_key.revoked", %{"prefix" => "emk-1234"}, [{"prefix", "emk-1234"}]},
        {"api_key.bound", %{"prefix" => "emk-1234", "auto" => true},
         [{"prefix", "emk-1234"}, {"source", "auto-mint"}]},
        {"runbook.created", %{"version" => 1}, [{"version", "v1"}]},
        {"runbook.updated", %{"to_version" => 2}, []},
        {"runbook.published", %{"version" => 3}, [{"version", "v3"}]},
        {"approval.approved", %{"grant_duration" => "1h", "grant_scope" => "action"},
         [{"duration", "1h"}, {"scope", "action"}]},
        {"approval.denied", %{"reason" => "too risky"}, [{"reason", "too risky"}]},
        {"approval.grant_used", %{"grant_id" => "0193aaaa-bbbb"}, [{"grant", "0193aaaa"}]},
        {"approval.grant_used", %{}, []},
        {"approval.grant_revoked", %{"action_id" => "linux.reboot"},
         [{"action", "linux.reboot"}]},
        {"approval.grant_revoked", %{}, []},
        {"run.cancel_requested", %{"reason" => "wrong host"}, [{"reason", "wrong host"}]},
        {"action_run.failed", %{"exit_code" => 1, "duration_ms" => 1_500},
         [{"exit_code", "1"}, {"duration_ms", "1.5s"}]},
        {"action_run.error", %{"exit_code" => 137}, [{"exit_code", "137"}]},
        {"action_run.timed_out", %{"duration_ms" => 125_000}, [{"duration_ms", "2m 5s"}]},
        {"action_run.denied", %{"reason" => "policy"}, [{"reason", "policy"}]},
        {"action_run.cancelled", %{"reason" => "operator"}, [{"reason", "operator"}]},
        {"policy.updated", %{"from_version" => 2, "to_version" => 3}, [{"version", "v2 → v3"}]}
      ]

      for {type, payload, expected} <- cases do
        actual = AuditSummary.summary_pairs(ev(type, payload))

        assert actual == expected,
               "#{type} with #{inspect(payload)} → #{inspect(actual)}, " <>
                 "expected #{inspect(expected)}"
      end
    end
  end
end

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
      assert AuditSummary.summary_pairs(
               ev("membership.role_changed", %{"from" => "operator", "to" => "admin"})
             ) == [{"Role", "Operator → Admin"}]
    end

    test "ignores no-op when from == to" do
      assert AuditSummary.summary_pairs(
               ev("membership.role_changed", %{"from" => "admin", "to" => "admin"})
             ) == []
    end
  end

  describe "user.email_changed" do
    test "renders from → to" do
      assert AuditSummary.summary_pairs(
               ev("user.email_changed", %{
                 "from" => "old@example.com",
                 "to" => "new@example.com"
               })
             ) == [{"Email", "old@example.com → new@example.com"}]
    end
  end

  describe "user.signed_in" do
    test "shows method when present" do
      assert AuditSummary.summary_pairs(ev("user.signed_in", %{"method" => "magic_link"})) == [
               {"Using", "magic link"}
             ]
    end

    test "drops to empty when method missing" do
      assert AuditSummary.summary_pairs(ev("user.signed_in", %{})) == []
    end

    test "keeps SSO capitalized and unknown method names intact" do
      assert AuditSummary.summary_pairs(ev("user.signed_in", %{"method" => "sso"})) ==
               [{"Using", "SSO"}]

      assert AuditSummary.summary_pairs(ev("user.signed_in", %{"method" => "CustomProvider"})) ==
               [{"Using", "CustomProvider"}]
    end
  end

  describe "user.other_sessions_revoked" do
    test "renders the count" do
      assert AuditSummary.summary_pairs(ev("user.other_sessions_revoked", %{"count" => 3})) == [
               {"Sessions", "3"}
             ]
    end

    test "ignores zero" do
      assert AuditSummary.summary_pairs(ev("user.other_sessions_revoked", %{"count" => 0})) == []
    end
  end

  describe "account.require_mfa_set" do
    test "renders required for true" do
      assert AuditSummary.summary_pairs(ev("account.require_mfa_set", %{"require_mfa" => true})) ==
               [{"MFA", "Required"}]
    end

    test "renders optional for false" do
      assert AuditSummary.summary_pairs(ev("account.require_mfa_set", %{"require_mfa" => false})) ==
               [{"MFA", "Optional"}]
    end
  end

  describe "runbook.updated" do
    test "shows a saved draft and its changed title" do
      assert AuditSummary.summary_pairs(
               ev("runbook.updated", %{
                 "operation" => "draft_saved",
                 "from_title" => "Old",
                 "title" => "New"
               })
             ) == [{"Draft", "Saved"}, {"Title", "Old → New"}]
    end
  end

  describe "run-family rows lead with the action" do
    test "success carries the bare command identity first" do
      assert [{"Action", "caddy.access_log_tail"}, {"Duration", "260ms"}] ==
               AuditSummary.summary_pairs(
                 ev("action_run.success", %{
                   "action" => "caddy.access_log_tail",
                   "duration_ms" => 260
                 })
               )
    end

    test "statuses without a special summary still name what was to run" do
      assert [{"Action", "linux.reboot_host"}] ==
               AuditSummary.summary_pairs(
                 ev("action_run.pending_approval", %{"action" => "linux.reboot_host"})
               )
    end

    test "grant_used names the action and its recorded use count" do
      assert [{"Action", "linux.uptime"}, {"Uses", "2/5"}] ==
               AuditSummary.summary_pairs(
                 ev("approval.grant_used", %{
                   "action" => "linux.uptime",
                   "grant_id" => "0af3c2d1-aaaa-bbbb-cccc-000000000000",
                   "uses_count" => 2,
                   "max_uses" => 5
                 })
               )
    end
  end

  describe "action_run.success" do
    test "renders sub-second duration in ms" do
      assert AuditSummary.summary_pairs(ev("action_run.success", %{"duration_ms" => 850})) == [
               {"Duration", "850ms"}
             ]
    end

    test "renders seconds when over 1s" do
      assert AuditSummary.summary_pairs(ev("action_run.success", %{"duration_ms" => 12_345})) == [
               {"Duration", "12.3s"}
             ]
    end

    test "renders minutes when over 1m" do
      assert AuditSummary.summary_pairs(
               ev("action_run.success", %{"duration_ms" => 5 * 60_000 + 30_000})
             ) == [{"Duration", "5m 30s"}]
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
               {"Default rules", "1"},
               {"Overrides added", "2"},
               {"Overrides removed", "1"}
             ]
    end

    test "empty changes produce no chips" do
      assert AuditSummary.summary_pairs(ev("policy.updated", %{"changes" => %{}})) == []
    end

    test "malformed nested payload values fall through without crashing the audit list" do
      assert AuditSummary.summary_pairs(
               ev("policy.updated", %{
                 "changes" => %{
                   "defaults" => "not-a-map",
                   "overrides" => %{"added" => "not-a-list"}
                 }
               })
             ) == []
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

      assert pairs == [{"Runner", "runner-1"}, {"Default rules", "1"}]
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

      assert pairs == [{"Default rules", "1"}]
    end
  end

  describe "policy.scope_deleted" do
    test "names the removed override's scope" do
      assert AuditSummary.summary_pairs(
               ev("policy.scope_deleted", %{"scope_type" => "group", "scope_value" => "db"})
             ) == [{"Group", "db"}]
    end
  end

  describe "graceful fallthrough" do
    test "unknown event types produce no chips" do
      assert AuditSummary.summary_pairs(ev("totally.made_up_event", %{"foo" => "bar"})) == []
    end

    test "nil payload is safe" do
      assert AuditSummary.summary_pairs(%{event_type: "user.signed_in", payload: nil}) == []
    end

    test "accepts atom keys (test fixtures)" do
      assert AuditSummary.summary_pairs(ev("user.signed_in", %{method: "magic_link"})) == [
               {"Using", "magic link"}
             ]
    end
  end

  describe "session.account_switched" do
    test "shows the role in the switched-to account" do
      assert AuditSummary.summary_pairs(ev("session.account_switched", %{"role" => "admin"})) == [
               {"Role", "Admin"}
             ]
    end

    test "no chip when role is absent" do
      assert AuditSummary.summary_pairs(ev("session.account_switched", %{})) == []
    end
  end

  describe "remaining event types (table)" do
    test "each renders its notable fact" do
      cases = [
        {"account.created", %{"plan" => "team", "slug" => "acme"},
         [{"Plan", "Team"}, {"Slug", "acme"}]},
        {"account.updated", %{"name" => "Acme", "slug" => nil}, []},
        {"membership.removed", %{"role" => "operator"}, [{"Previous role", "Operator"}]},
        {"membership.runner_access_changed",
         %{"before" => %{"mode" => "none"}, "after" => %{"mode" => "restricted"}},
         [{"Runners", "None → Selected"}]},
        {"membership.runner_access_synced_via_scim",
         %{"before" => %{"mode" => "restricted"}, "after" => %{"mode" => "all"}},
         [{"Runners", "Selected → All"}]},
        {"sso.provider_updated",
         %{"before" => %{"mode" => "none"}, "after" => %{"mode" => "restricted"}},
         [{"Runners", "None → Selected"}]},
        {"sso.group_runner_access_mapping_created",
         %{"before" => %{"mode" => "none"}, "after" => %{"mode" => "all"}},
         [{"Runners", "None → All"}]},
        {"sso.group_runner_access_mapping_updated",
         %{"before" => %{"mode" => "restricted"}, "after" => %{"mode" => "all"}},
         [{"Runners", "Selected → All"}]},
        {"sso.group_runner_access_mapping_deleted",
         %{"before" => %{"mode" => "all"}, "after" => %{"mode" => "none"}},
         [{"Runners", "All → None"}]},
        {"membership.invitation_accepted", %{"role" => "admin"}, [{"Role", "Admin"}]},
        {"user.invitation_accepted", %{"role" => "viewer"}, [{"Role", "Viewer"}]},
        {"user.invited", %{"role" => "operator"}, [{"Invited role", "Operator"}]},
        {"user.sign_in_failed", %{"reason" => "bad_password"}, [{"Reason", "bad_password"}]},
        {"user.mfa_failed", %{"reason" => "invalid_otp"},
         [{"Reason", "Invalid authenticator code"}]},
        {"user.mfa_rate_limited",
         %{"scope" => "mfa_challenge", "attempt_limit" => 5, "window_seconds" => 300},
         [{"Step", "Code verification"}, {"Limit", "5"}, {"Window", "5 minutes"}]},
        {"user.email_change_rate_limited",
         %{"scope" => "email_change_issue", "attempt_limit" => 5, "window_seconds" => 900},
         [{"Step", "Code delivery"}, {"Limit", "5"}, {"Window", "15 minutes"}]},
        {"user.inbox_step_up_rate_limited",
         %{"scope" => "inbox_step_up", "attempt_limit" => 5, "window_seconds" => 300},
         [{"Step", "Code verification"}, {"Limit", "5"}, {"Window", "5 minutes"}]},
        {"user.mfa_enrollment_requested", %{}, []},
        {"user.mfa_recovery_code_used", %{"remaining" => 7}, [{"Codes left", "7"}]},
        {"user.session_revoked", %{"anything" => "x"}, []},
        {"user.profile_updated", %{"full_name" => "Ada"}, [{"Name", "Ada"}]},
        {"user.profile_updated", %{"full_name" => ""}, [{"Name", "Removed"}]},
        {"user.updated_by_admin", %{"full_name" => "Bob"}, [{"Name", "Bob"}]},
        {"runner.registered", %{"group" => "prod", "hostname" => "host-1"},
         [{"Group", "prod"}, {"Hostname", "host-1"}]},
        {"runner.disconnected", %{"reason" => "drain"},
         [{"Reason", "Connection ended unexpectedly."}]},
        {"enrollment_key.created", %{"group" => "prod", "reusable" => true},
         [{"Use", "Reusable"}]},
        {"enrollment_key.created", %{"reusable" => false}, [{"Use", "Single-use"}]},
        {"enrollment_key.revoked", %{"prefix" => "eak-1234"}, [{"Prefix", "eak-1234"}]},
        {"enrollment_key.bound", %{"prefix" => "eak-1234", "auto" => true},
         [{"Prefix", "eak-1234"}, {"Source", "Runner setup"}]},
        {"enrollment_key.bound", %{"prefix" => "eak-1234"}, [{"Prefix", "eak-1234"}]},
        {"api_key.created", %{"prefix" => "emk-1234", "kind" => "audit_export"},
         [{"Prefix", "emk-1234"}, {"Type", "Audit export"}]},
        {"api_key.created", %{"prefix" => "emk-1234"}, [{"Prefix", "emk-1234"}]},
        {"api_key.revoked", %{"prefix" => "emk-1234"}, [{"Prefix", "emk-1234"}]},
        {"api_key.bound", %{"prefix" => "emk-1234", "auto" => true},
         [{"Prefix", "emk-1234"}, {"Source", "Created automatically"}]},
        {"runbook.created", %{"name" => "diagnostics"}, []},
        {"runbook.updated", %{"to_version" => 2}, []},
        {"runbook.published", %{"version" => 3}, [{"Version", "v3"}]},
        {"approval.approved", %{"grant_duration" => "one_hour", "grant_scope" => "exact_args"},
         [{"Standing grant", "1 hour"}, {"Arguments", "Same arguments"}]},
        {"approval.overridden",
         %{"approved_count" => 1, "min_approvals" => 3, "reason" => "restore service"},
         [{"Approvals", "1/3"}, {"Reason", "restore service"}]},
        {"approval.denied", %{"reason" => "too risky"}, [{"Reason", "too risky"}]},
        {"approval.grant_used", %{"grant_id" => "0193aaaa-bbbb"}, []},
        {"approval.grant_used", %{}, []},
        {"approval.grant_revoked", %{"action_id" => "linux.reboot"},
         [{"Action", "linux.reboot"}]},
        {"approval.grant_revoked", %{}, []},
        {"run.cancel_requested", %{"reason" => "wrong host"}, [{"Reason", "wrong host"}]},
        {"action_run.failed", %{"exit_code" => 1, "duration_ms" => 1_500},
         [{"Exit code", "1"}, {"Duration", "1.5s"}]},
        {"action_run.error", %{"exit_code" => 137}, [{"Exit code", "137"}]},
        {"action_run.timed_out", %{"duration_ms" => 125_000}, [{"Duration", "2m 5s"}]},
        {"action_run.denied", %{"policy_reason" => "policy"}, [{"Reason", "policy"}]},
        {"action_run.cancelled", %{"reason" => "operator"}, [{"Reason", "operator"}]},
        {"policy.updated", %{"from_version" => 2, "to_version" => 3}, [{"Version", "v2 → v3"}]}
      ]

      for {type, payload, expected} <- cases do
        actual = AuditSummary.summary_pairs(ev(type, payload))

        assert actual == expected,
               "#{type} with #{inspect(payload)} → #{inspect(actual)}, " <>
                 "expected #{inspect(expected)}"
      end
    end
  end

  describe "recorded facts and historical gaps" do
    test "Slack support changes retain the recorded destination and clearing" do
      url = "https://workspace.slack.com/archives/C01234567"

      for {before_url, after_url, expected} <- [
            {nil, url, "Not set → #{url}"},
            {url, nil, "#{url} → Not set"}
          ] do
        payload = %{
          "changes" => %{"support_slack_url" => %{"before" => before_url, "after" => after_url}}
        }

        assert AuditSummary.summary_pairs(ev("account.updated", payload)) == [
                 {"Slack support", expected}
               ]
      end
    end

    test "account settings show only actual changes, including explicit false and null" do
      payload = %{
        changes: %{
          name: %{before: "same", after: "same"},
          monthly_report_opt_out: %{before: false, after: true},
          runner_inactive_retention_hours: %{before: nil, after: 168},
          pack_unseen_retention_days: %{before: 30, after: nil}
        }
      }

      assert AuditSummary.summary_pairs(ev("account.updated", payload)) == [
               {"Monthly reports", "On → Off"},
               {"Pack cleanup", "30 days → Off"},
               {"Runner cleanup", "Off → 7 days"}
             ]

      assert AuditSummary.summary_pairs(ev("account.updated", %{name: "Unchanged snapshot"})) ==
               []

      assert AuditSummary.summary_pairs(ev("account.require_mfa_set", %{require_mfa: false})) ==
               [{"MFA", "Optional"}]

      assert AuditSummary.summary_pairs(ev("account.require_sso_set", %{require_sso: false})) ==
               [{"SSO", "Optional"}]
    end

    test "missing grant limit is not the same as an explicit removed limit" do
      assert AuditSummary.summary_pairs(ev("account.max_grant_lifetime_set", %{})) == []

      assert AuditSummary.summary_pairs(
               ev("account.max_grant_lifetime_set", %{max_grant_lifetime_seconds: nil})
             ) == [{"Account limit", "Removed"}]

      assert AuditSummary.summary_pairs(
               ev("account.max_grant_lifetime_set", %{max_grant_lifetime_seconds: 0})
             ) == [{"Standing grants", "Disabled"}]

      assert AuditSummary.summary_pairs(
               ev("account.max_grant_lifetime_set", %{max_grant_lifetime_seconds: 2_592_000})
             ) == [{"Maximum lifetime", "30 days"}]
    end

    test "saved roles are readable without altering unknown role names" do
      assert AuditSummary.summary_pairs(
               ev("session.account_switched", %{role: "billing_manager"})
             ) ==
               [{"Role", "Billing manager"}]

      assert AuditSummary.summary_pairs(ev("session.account_switched", %{role: "CustomRole"})) ==
               [{"Role", "CustomRole"}]

      assert AuditSummary.summary_pairs(ev("membership.invitation_resent", %{role: "operator"})) ==
               [{"Invited role", "Operator"}]

      assert AuditSummary.summary_pairs(ev("membership.erased", %{role: "owner"})) ==
               [{"Previous role", "Owner"}]
    end

    test "access changes include selections within the same mode" do
      before_access = %{
        mode: "restricted",
        groups: ["database"],
        runner_ids: ["old-id"],
        pack_mode: "restricted",
        pack_ids: ["linux"]
      }

      after_access = %{
        mode: "restricted",
        groups: ["web"],
        runner_ids: ["new-id"],
        pack_mode: "restricted",
        pack_ids: ["linux", "nginx"]
      }

      assert AuditSummary.summary_pairs(
               ev("membership.runner_access_changed", %{
                 before: before_access,
                 after: after_access
               })
             ) == [
               {"Groups", "database → web"},
               {"Runners", "1 added, 1 removed"},
               {"Packs", "linux → linux, nginx"}
             ]
    end

    test "provider configuration and safe credential flags are visible" do
      payload = %{
        changes: %{
          default_role: %{before: "viewer", after: "operator"},
          enabled: %{before: true, after: false},
          satisfies_mfa: %{before: false, after: true}
        },
        client_secret_rotated: true,
        scim_token_revoked: true
      }

      assert AuditSummary.summary_pairs(ev("sso.provider_updated", payload)) == [
               {"Default role", "Viewer → Operator"},
               {"SSO", "On → Off"},
               {"SSO satisfies MFA", "Off → On"},
               {"Client secret", "Rotated"},
               {"SCIM token", "Revoked"}
             ]
    end

    test "email confirmation failures and MFA session assurance are distinct" do
      for type <- ["user.email_change_code_failed", "user.mfa_enrollment_failed"] do
        assert AuditSummary.summary_pairs(ev(type, %{reason: "invalid"})) ==
                 [{"Reason", "Invalid or expired code"}]
      end

      assert AuditSummary.summary_pairs(
               ev("user.oidc_identity_step_up_failed", %{purpose: "unlink", reason: "invalid"})
             ) == [{"For", "Removing SSO"}, {"Reason", "Invalid or expired code"}]

      assert AuditSummary.summary_pairs(ev("user.mfa_verified", %{factor: "totp"})) ==
               [{"Using", "authenticator"}]

      assert AuditSummary.summary_pairs(ev("user.mfa_verified", %{session_verified: true})) ==
               [{"Session", "Verified"}]

      assert AuditSummary.summary_pairs(ev("user.profile_updated", %{full_name: nil})) ==
               [{"Name", "Removed"}]

      assert AuditSummary.summary_pairs(ev("user.profile_updated", %{})) == []
    end

    test "key summaries preserve lifetime, limits and replacement links" do
      assert AuditSummary.summary_pairs(
               ev("enrollment_key.created", %{reusable: true, max_uses: 5, expires_at: nil})
             ) == [{"Use", "Reusable"}, {"Use limit", "5"}, {"Expiration", "No expiration date"}]

      assert AuditSummary.summary_pairs(ev("enrollment_key.created", %{reusable: true})) ==
               [{"Use", "Reusable"}]

      assert AuditSummary.summary_pairs(
               ev("runner.credential_rotated", %{
                 token_prefix: "new-prefix",
                 previous_token_prefix: "old-prefix",
                 expires_at: "2026-10-01T14:30:00Z"
               })
             ) == [
               {"Key", "new-prefix"},
               {"Replaces", "old-prefix"},
               {"Expires", "Oct 1, 2026, 14:30 UTC"}
             ]

      assert AuditSummary.summary_pairs(
               ev("api_key.created", %{kind: "mcp", replaces_prefix: "old-prefix"})
             ) == [{"Type", "AI agent"}, {"Replaces", "old-prefix"}]

      assert AuditSummary.summary_pairs(
               ev("api_key.auto_rotated", %{successor_prefix: "new-prefix"})
             ) == [{"Replacement key", "new-prefix"}]
    end

    test "pack summaries use saved reporters and counts rather than capped samples" do
      assert AuditSummary.summary_pairs(
               ev("pack_trust_drift_detected", %{runner_name: "saved-runner-name"})
             ) == [{"Review", "Required"}, {"Runner", "saved-runner-name"}]

      assert AuditSummary.summary_pairs(
               ev("pack_retention_swept", %{count: 501, versions: ["a@1"], unseen_days: 7})
             ) == [{"Removed", "501"}, {"Not reported for", "7 days"}]

      assert AuditSummary.summary_pairs(ev("pack_trust_rejected", %{})) == []

      assert AuditSummary.summary_pairs(ev("pack_trust_rejected", %{trusted_hash: nil})) ==
               [{"Trust", "Pack remains untrusted"}]

      assert AuditSummary.summary_pairs(ev("pack_trust_rejected", %{trusted_hash: "saved-hash"})) ==
               [{"Trust", "Previous trusted hash kept"}]
    end

    test "blocked request summaries distinguish requested actions from resolved targets" do
      assert AuditSummary.summary_pairs(
               ev("dispatch_blocked_pack_untrusted", %{requested_action_id: "service.restart"})
             ) == [{"Action", "service.restart"}]

      assert AuditSummary.summary_pairs(
               ev("dispatch_blocked_target_unavailable", %{
                 requested_action_id: "service.restart",
                 requested_pack_ref: "system@1"
               })
             ) == [{"Requested action", "service.restart"}]

      assert AuditSummary.summary_pairs(
               ev("dispatch_blocked_pack_untrusted", %{action_id: "service.restart"})
             ) == [{"Action", "service.restart"}]
    end

    test "votes, waived requirements, and standing-grant limits remain distinct" do
      assert AuditSummary.summary_pairs(
               ev("approval.decision_recorded", %{
                 decision: "approve",
                 approved_count: 1,
                 min_approvals: 3
               })
             ) == [{"Decision", "Approve"}, {"Approvals", "1/3"}]

      assert AuditSummary.summary_pairs(
               ev("approval.overridden", %{
                 approved_count: 1,
                 min_approvals: 3,
                 remaining_approvals_waived: 2,
                 self_approval_waived: true,
                 reason: "Restore service"
               })
             ) == [
               {"Approvals", "1/3"},
               {"Approvals waived", "2"},
               {"Self-approval restriction", "Waived"},
               {"Reason", "Restore service"}
             ]

      assert AuditSummary.summary_pairs(
               ev("approval.approved", %{
                 grant_duration: "one_day",
                 grant_scope: "any_args",
                 grant_max_uses: 10
               })
             ) == [
               {"Standing grant", "1 day"},
               {"Arguments", "Any arguments"},
               {"Use limit", "10"}
             ]

      assert AuditSummary.summary_pairs(
               ev("approval.grant_used", %{uses_count: 12, max_uses: nil})
             ) ==
               [{"Uses", "12"}]
    end

    test "policy explanations and execution failures never become requester reasons" do
      payload = %{
        action: "linux.restart",
        reason: "Please restore service",
        policy_reason: "Production changes require approval.",
        error_message: "The service is unavailable."
      }

      assert AuditSummary.summary_pairs(ev("action_run.denied", payload)) ==
               [{"Action", "linux.restart"}, {"Reason", "Production changes require approval."}]

      assert AuditSummary.summary_pairs(ev("action_run.refused", payload)) ==
               [{"Action", "linux.restart"}, {"Reason", "The service is unavailable."}]

      assert AuditSummary.summary_pairs(
               ev("action_run.cancelled", %{reason: "approval expired without decision"})
             ) == [{"Reason", "Approval expired."}]

      assert AuditSummary.summary_pairs(ev("action_run.cancelled", %{reason: "Keep THIS case"})) ==
               [{"Reason", "Keep THIS case"}]
    end

    test "runbook summaries show operations without inventing versions or duplicate statuses" do
      assert AuditSummary.summary_pairs(
               ev("runbook.updated", %{
                 operation: "draft_discarded",
                 from_title: "Same",
                 title: "Same"
               })
             ) == [{"Draft", "Discarded"}]

      assert AuditSummary.summary_pairs(ev("runbook.created", %{})) == []

      assert AuditSummary.summary_pairs(ev("runbook.execution_succeeded", %{status: "succeeded"})) ==
               []

      assert AuditSummary.summary_pairs(
               ev("runbook.item_failed", %{
                 step_id: "check",
                 attempt_number: 2,
                 code: "raw_code",
                 message: "Useful reason"
               })
             ) == [{"Step", "check"}, {"Attempt", "2"}, {"Reason", "Useful reason"}]
    end

    test "saved policy approval and ordered-override changes survive an incomplete old diff" do
      allow = %{"action" => "linux.*", "decision" => "allow"}
      deny = %{"action" => "linux.restart", "decision" => "deny"}

      before_rules = %{
        "approval" => %{"min_approvals" => 1, "allow_self_approval" => true},
        "overrides" => [allow, deny]
      }

      after_rules = %{
        "approval" => %{"min_approvals" => 2, "allow_self_approval" => false},
        "overrides" => [deny, allow]
      }

      assert AuditSummary.summary_pairs(
               ev("policy.updated", %{before: before_rules, after: after_rules, changes: %{}})
             ) == [
               {"Required approvers", "1 → 2"},
               {"Self-approval", "Allowed → Not allowed"},
               {"Override order", "Changed"}
             ]
    end

    test "export receipts state read counts without claiming delivery" do
      assert AuditSummary.summary_pairs(ev("audit.exported", %{transport: "csv", count: 42})) ==
               [{"Format", "CSV"}, {"Events", "42"}]

      assert AuditSummary.summary_pairs(ev("audit.exported", %{transport: "siem", count: 25})) ==
               [{"Using", "Export API"}, {"Events", "25"}]
    end

    test "subscription status and removed schedules show even when the plan did not change" do
      assert AuditSummary.summary_pairs(
               ev("subscription.changed", %{
                 from: "team",
                 to: "team",
                 from_status: "active",
                 to_status: "past_due"
               })
             ) == [{"Status", "Active → Past due"}]

      assert AuditSummary.summary_pairs(
               ev("subscription.changed", %{
                 from: "team",
                 to: "team",
                 from_scheduled_change_action: "cancel",
                 to_scheduled_change_action: nil,
                 from_scheduled_change_effective_at: "2026-10-01T00:00:00Z",
                 to_scheduled_change_effective_at: nil
               })
             ) == [{"Scheduled change", "Removed"}]

      assert AuditSummary.summary_pairs(ev("subscription.changed", %{from: "team", to: "team"})) ==
               []
    end
  end
end

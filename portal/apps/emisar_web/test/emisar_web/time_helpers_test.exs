defmodule EmisarWeb.TimeHelpersTest do
  use ExUnit.Case, async: true
  import EmisarWeb.TimeHelpers

  describe "last_used/1" do
    test "renders nil as \"never\" (the convention every LV expects)" do
      assert last_used(nil) == "never"
    end

    test "delegates non-nil timestamps to relative_time/2" do
      ts = DateTime.utc_now() |> DateTime.add(-2 * 60, :second)
      # The relative formatter is locale + window-sensitive; rather than
      # pin its exact text, assert we got the SAME string as the helper
      # we're delegating to. If `relative_time/2` changes, this test
      # keeps passing as long as `last_used/1` keeps delegating.
      assert last_used(ts) == relative_time(ts)
    end
  end

  describe "event_tone/1" do
    test "failures and errors are :danger" do
      for t <- ~w[user.sign_in_failed user.mfa_failed user.password_change_failed
                  action_run.failed action_run.error runner.error action_run.timed_out] do
        assert event_tone(t) == :danger, "expected #{t} to be :danger"
      end
    end

    test "denials and access taken away are :warn" do
      for t <- ~w[approval.denied action_run.denied auth_key.revoked user.session_revoked
                  runner.disabled runner.deleted membership.removed membership.suspended
                  approval.expired action_run.cancelled approval.grant_revoked] do
        assert event_tone(t) == :warn, "expected #{t} to be :warn"
      end
    end

    test "routine events are :neutral" do
      for t <- ~w[action_run.success approval.approved api_key.created runner.connected
                  runner.enabled user.signed_in session.account_switched policy.evaluated] do
        assert event_tone(t) == :neutral, "expected #{t} to be :neutral"
      end
    end

    test "nil and non-binary fall back to :neutral" do
      assert event_tone(nil) == :neutral
      assert event_tone(42) == :neutral
    end
  end

  describe "relative_time/2" do
    test "buckets past offsets" do
      now = DateTime.utc_now()

      assert relative_time(now) == "just now"
      assert relative_time(DateTime.add(now, -30, :second)) == "30s ago"
      assert relative_time(DateTime.add(now, -120, :second)) == "2m ago"
      assert relative_time(DateTime.add(now, -7_200, :second)) == "2h ago"
      assert relative_time(DateTime.add(now, -3 * 86_400, :second)) == "3d ago"
      # Beyond a week: a calendar date like "May 18".
      assert relative_time(DateTime.add(now, -30 * 86_400, :second)) =~ ~r/^[A-Z][a-z]{2} \d/
    end

    test "buckets future offsets (expiries)" do
      now = DateTime.utc_now()

      assert relative_time(DateTime.add(now, 90, :second)) == "in 1m"
      assert relative_time(DateTime.add(now, 7_200, :second)) == "in 2h"
      assert relative_time(DateTime.add(now, 2 * 86_400, :second)) == "in 2d"
    end

    test "nil renders the placeholder; NaiveDateTime is treated as UTC" do
      assert relative_time(nil) == "—"
      assert relative_time(nil, placeholder: "n/a") == "n/a"

      naive = NaiveDateTime.add(NaiveDateTime.utc_now(), -300, :second)
      assert relative_time(naive) == "5m ago"
    end
  end

  describe "absolute_time/2" do
    test "renders the UTC stamp, tolerating nil and naive datetimes" do
      assert absolute_time(~U[2026-05-21 14:03:00Z]) == "May 21, 14:03 UTC"
      assert absolute_time(~N[2026-05-21 14:03:00]) == "May 21, 14:03 UTC"
      assert absolute_time(nil) == "—"
    end
  end

  describe "format_duration/1" do
    test "scales ms → s → m" do
      assert format_duration(nil) == "—"
      assert format_duration(312) == "312ms"
      assert format_duration(1_300) == "1.3s"
      assert format_duration(240_000) == "4m"
    end
  end

  describe "format_json/1" do
    test "pretty-prints maps; nil is an empty object" do
      assert format_json(nil) == "{}"
      assert format_json(%{"a" => 1}) == "{\n  \"a\": 1\n}"
    end
  end

  describe "format_event_type/1" do
    test "known types use the curated label table" do
      assert format_event_type("runner.connected") =~ ~r/^[A-Z]/
    end

    test "unknown types are humanized, never raw machine code" do
      assert format_event_type("warp.core_breach") == "Warp core breach"
      assert format_event_type(nil) == "—"
    end
  end

  describe "run actor / source labels" do
    test "prefers MCP client name, then API key name, then the source" do
      assert run_actor(%{client_info: %{"name" => "Claude Code"}}) == "Claude Code"
      assert run_actor(%{client_info: %{}, api_key: %{name: "ci-bot"}}) == "ci-bot"
      assert run_actor(%{client_info: %{}, api_key: nil, source: :operator}) == "Operator"
      assert run_actor(%{}) == "—"
    end

    test "client_version reads the snapshotted version" do
      assert client_version(%{client_info: %{"version" => "1.2.3"}}) == "1.2.3"
      assert client_version(%{client_info: %{}}) == nil
    end

    test "format_source humanizes the run-source enum" do
      assert format_source(:mcp) == "MCP / LLM"
      assert format_source(:runbook) == "Runbook"
      assert format_source(:scheduled) == "Scheduled"
      assert format_source(:from_the_future) == "—"
    end
  end
end

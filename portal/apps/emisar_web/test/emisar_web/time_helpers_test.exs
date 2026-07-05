defmodule EmisarWeb.TimeHelpersTest do
  use ExUnit.Case, async: true
  import EmisarWeb.TimeHelpers

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
    test "the PERSON leads, then MCP client name, then API key name, then the source" do
      # A loaded requesting user beats the agent name — usernames tell
      # operators apart where every LLM key is named "Claude Code".
      assert run_actor(%{
               requested_by: %{full_name: "Maya Chen", email: "m@x.co"},
               client_info: %{"name" => "Claude Code"}
             }) == "Maya Chen"

      assert run_actor(%{requested_by: %{full_name: nil, email: "m@x.co"}}) == "m@x.co"
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
      assert format_source(:mcp) == "LLM agent"
      assert format_source(:runbook) == "Runbook"
      assert format_source(:scheduled) == "Scheduled"
      assert format_source(:from_the_future) == "—"
    end
  end
end

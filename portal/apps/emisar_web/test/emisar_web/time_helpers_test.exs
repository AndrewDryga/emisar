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

  describe "run_who_via/1" do
    test "the HUMAN leads; the requesting operator beats the agent name" do
      # An operator run: the person leads, no channel ("via portal" says nothing).
      assert run_who_via(%{
               source: :operator,
               requested_by: %{full_name: "Maya Chen", email: "m@x.co"}
             }) == {"Maya Chen", nil}

      # full_name falls back to email.
      assert run_who_via(%{source: :operator, requested_by: %{full_name: nil, email: "m@x.co"}}) ==
               {"m@x.co", nil}
    end

    test "an MCP run names the accountable human (the key owner) + the key as via" do
      # A human requested it: they lead, the API key is the channel.
      assert run_who_via(%{
               source: :mcp,
               requested_by: %{full_name: "Jordan", email: "j@x.co"},
               api_key: %{
                 name: "Claude Code",
                 created_by: %{full_name: "Jordan", email: "j@x.co"}
               }
             }) == {"Jordan", "Claude Code"}

      # No requester recorded → the key's OWNER is the accountable human.
      assert run_who_via(%{
               source: :mcp,
               requested_by: nil,
               api_key: %{name: "Claude Code", created_by: %{full_name: nil, email: "owner@x.co"}}
             }) == {"owner@x.co", "Claude Code"}
    end

    test "an MCP run with no resolvable human shows only its channel" do
      # Missing/deleted user on both sides: who is nil, the key name is via.
      assert run_who_via(%{source: :mcp, requested_by: nil, api_key: %{name: "ci-bot"}}) ==
               {nil, "ci-bot"}

      # An unloaded assoc (%Ecto.Association.NotLoaded{}) falls through like nil.
      assert run_who_via(%{source: :mcp, requested_by: %Ecto.Association.NotLoaded{}}) ==
               {nil, "LLM agent"}
    end

    test "a legacy/system row with no human and no signal channel is {nil, nil}" do
      assert run_who_via(%{source: :operator, requested_by: nil}) == {nil, nil}
      assert run_who_via(%{}) == {nil, nil}
      assert run_who_via(%{source: :runbook}) == {nil, "runbook"}
    end
  end

  describe "run_actor/1" do
    test "composes the one-line label, human first, channel second" do
      assert run_actor(%{
               source: :mcp,
               requested_by: %{full_name: "Jordan", email: "j@x.co"},
               api_key: %{name: "Claude Code", created_by: %{email: "j@x.co"}}
             }) == "Jordan via Claude Code"

      assert run_actor(%{source: :operator, requested_by: %{full_name: "Maya", email: "m@x.co"}}) ==
               "Maya"

      assert run_actor(%{source: :mcp, requested_by: nil, api_key: %{name: "ci-bot"}}) == "ci-bot"
      assert run_actor(%{}) == "—"
    end
  end

  describe "client_version/1" do
    test "reads the snapshotted version" do
      assert client_version(%{client_info: %{"version" => "1.2.3"}}) == "1.2.3"
      assert client_version(%{client_info: %{}}) == nil
    end
  end

  describe "format_source/1" do
    test "humanizes the run-source enum" do
      assert format_source(:mcp) == "LLM agent"
      assert format_source(:runbook) == "Runbook"
      assert format_source(:scheduled) == "Scheduled"
      assert format_source(:from_the_future) == "—"
    end
  end
end

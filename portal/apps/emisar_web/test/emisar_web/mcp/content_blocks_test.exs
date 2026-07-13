defmodule EmisarWeb.MCP.ContentBlocksTest do
  @moduledoc """
  Rendering of dispatch results into MCP content blocks. Guards the two
  bugs surfaced when testing the live server from Claude Code:

    * a dispatched-but-not-terminal run must surface its run_id (so the
      LLM can `wait_for_run`) — it used to render a bare "status=sent";
    * a failed run must surface the error so the LLM sees the failure.
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ContentBlocks

  defp text(blocks), do: Enum.map_join(blocks, "\n", & &1.text)

  describe "from_runs/1 — in-flight (non-terminal) run" do
    test "surfaces run_id + wait_for_run instead of a bare status line" do
      {blocks, is_error} =
        ContentBlocks.from_runs([%{id: "run-abc-123", status: "sent", runner: "web-1"}])

      body = text(blocks)
      assert body =~ "run-abc-123"
      assert body =~ "wait_for_run"
      refute is_error
    end

    test "running runs are treated the same as sent" do
      {blocks, _} = ContentBlocks.from_runs([%{id: "run-x", status: "running"}])
      assert text(blocks) =~ "run-x"
      assert text(blocks) =~ "wait_for_run"
    end
  end

  describe "from_runs/1 — terminal run" do
    test "a failed run surfaces the error_message and flags isError" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            id: "run-9",
            status: "failed",
            error_message: "fork/exec /usr/bin/caddy: no such file or directory",
            runner: "web-1"
          }
        ])

      assert text(blocks) =~ "fork/exec /usr/bin/caddy: no such file or directory"
      assert is_error
    end

    test "a runner-REFUSED dispatch (trust-check rejection) flags isError, not success" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            id: "run-r",
            status: "refused",
            error_message: "client signature missing or stale",
            runner: "web-1"
          }
        ])

      # :refused = the runner rejected the dispatch on a pre-exec trust check, so
      # it never ran (no exit_code). It must NOT be reported to the LLM as success.
      assert text(blocks) =~ "client signature missing or stale"
      assert is_error
    end

    test "a successful run surfaces stdout and is not an error" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{id: "run-1", status: "success", exit_code: 0, stdout: "v2.7.6", stderr: ""}
        ])

      assert text(blocks) =~ "v2.7.6"
      assert text(blocks) =~ "status=success"
      refute is_error
    end

    test "a bounded output preview states that it is incomplete" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            id: "run-tail",
            status: "success",
            exit_code: 0,
            stdout: "last line",
            output_events_truncated: true
          }
        ])

      assert text(blocks) =~ "Output preview is truncated"
      refute is_error
    end

    test "a non-zero exit flags isError even when status isn't a failure word" do
      {_blocks, is_error} =
        ContentBlocks.from_runs([%{id: "r", status: "success", exit_code: 1, stdout: ""}])

      assert is_error
    end

    test "a cancelled run surfaces the exact human approval denial reason" do
      reason = "approval denied: maintenance freeze until 22:00 UTC"

      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{id: "run-denied", status: "cancelled", reason: reason}
        ])

      assert text(blocks) =~ "Cancellation reason: #{reason}"
      assert is_error
    end

    test "a cancelled run surfaces the default approval denial reason" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{id: "run-denied-default", status: "cancelled", reason: "approval denied"}
        ])

      assert text(blocks) =~ "Cancellation reason: approval denied"
      assert is_error
    end

    test "a successful run does not expose its dispatch justification as a cancellation reason" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{id: "run-ok", status: "success", exit_code: 0, reason: "routine maintenance"}
        ])

      refute text(blocks) =~ "routine maintenance"
      refute is_error
    end
  end

  describe "from_runs/1 — approval gate" do
    test "pending_approval leads with the ⏸ line naming the action + reason" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            id: "run-7",
            status: "pending_approval",
            action_id: "debugging.kill_pid",
            policy: %{reason: "high-risk actions require approval"}
          }
        ])

      body = text(blocks)
      assert body =~ "⏸ pending approval — debugging.kill_pid"
      assert body =~ "high-risk actions require approval"
      assert body =~ "a human approves it in the portal"
      assert body =~ "run-7"
      assert body =~ "wait_for_run"
      refute is_error
    end

    test "an approved (require_approval) run that executed is prefixed ✓ approved" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            id: "run-8",
            status: "success",
            exit_code: 0,
            stdout: "terminated",
            policy: %{decision: "require_approval"}
          }
        ])

      body = text(blocks)
      assert body =~ "✓ approved · audit event recorded"
      assert body =~ "terminated"
      refute is_error
    end

    test "an auto-allowed run is not labelled approved" do
      {blocks, _} =
        ContentBlocks.from_runs([
          %{
            id: "run-9",
            status: "success",
            exit_code: 0,
            stdout: "ok",
            policy: %{decision: "allow"}
          }
        ])

      refute text(blocks) =~ "✓ approved"
    end
  end

  describe "from_runs/1 — policy denial" do
    test "denied_by_policy renders the verbatim reason and flags isError" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            runner: "web-1",
            status: "denied_by_policy",
            reason: "high-risk actions are denied outside business hours"
          }
        ])

      body = text(blocks)
      assert body =~ "Denied by policy: high-risk actions are denied outside business hours"
      assert is_error
    end

    test "a denial prefers the policy.reason over the top-level reason" do
      {blocks, true} =
        ContentBlocks.from_runs([
          %{
            status: "denied",
            reason: "fallback",
            policy: %{reason: "critical tier is always denied"}
          }
        ])

      assert text(blocks) =~ "Denied by policy: critical tier is always denied"
    end
  end

  describe "from_runs/1 — empty + multi-run" do
    test "an empty runs list renders (no output)" do
      {blocks, is_error} = ContentBlocks.from_runs([])

      assert text(blocks) == "(no output)"
      refute is_error
    end

    test "a fan-out prefixes each run's blocks with [runner_name]" do
      {blocks, _} =
        ContentBlocks.from_runs([
          %{id: "run-a", status: "success", exit_code: 0, stdout: "alpha", runner: "web-1"},
          %{id: "run-b", status: "success", exit_code: 0, stdout: "bravo", runner: "web-2"}
        ])

      body = text(blocks)
      assert body =~ "[web-1]"
      assert body =~ "[web-2]"
    end

    test "a single run is NOT prefixed (multi is false for one run)" do
      {blocks, _} =
        ContentBlocks.from_runs([
          %{id: "run-a", status: "success", exit_code: 0, stdout: "alpha", runner: "web-1"}
        ])

      refute text(blocks) =~ "[web-1]"
    end
  end

  describe "from_runs/1 — generic unknown-error payload (no internal leak)" do
    test "the Service `error: \"unknown\"` payload renders a generic message + isError" do
      # When Service.dispatch_tool can't map an internal error term, it emits a
      # static `unknown` payload (the raw term is logged server-side, never put
      # here). The renderer must surface only that human message and flag the
      # error — no internal ids / struct fields to read because none are present.
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{
            runner: "web-1",
            status: "error",
            error: "unknown",
            message:
              "Unrecognized error from the cloud — the LLM can't recover from this on its " <>
                "own. Report it to Emisar support."
          }
        ])

      body = text(blocks)
      assert is_error
      assert body =~ "Error: unknown"
      assert body =~ "Report it to Emisar support."
      # Nothing resembling an internal term/struct leaked into the block.
      refute body =~ "%{"
      refute body =~ ":error"
    end
  end

  describe "from_runs/1 — IL-14 unknown-key safety" do
    test "a novel string key never raises and never grows the atom table" do
      # A made-up key that has no existing atom — string_field/numeric_field
      # resolve fields via String.to_existing_atom, which must be rescued so an
      # attacker-influenced payload can't mint atoms or crash the renderer.
      novel = "definitely-not-an-existing-atom-#{System.unique_integer([:positive])}"

      {blocks, _is_error} =
        ContentBlocks.from_runs([
          %{"status" => "success", "stdout" => "ok", novel => "ignored"}
        ])

      # Rendered fine off the string keys; the novel key was simply not read.
      assert text(blocks) =~ "ok"
      # And it never became an atom.
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end
  end
end

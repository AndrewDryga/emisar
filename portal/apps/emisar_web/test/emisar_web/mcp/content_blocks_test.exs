defmodule EmisarWeb.Mcp.ContentBlocksTest do
  @moduledoc """
  Rendering of dispatch results into MCP content blocks. Guards the two
  bugs surfaced when testing the live server from Claude Code:

    * a dispatched-but-not-terminal run must surface its run_id (so the
      LLM can `wait_for_run`) — it used to render a bare "status=sent";
    * a failed run must surface the error so the LLM sees the failure.
  """
  use ExUnit.Case, async: true

  alias EmisarWeb.Mcp.ContentBlocks

  defp text(blocks), do: blocks |> Enum.map(& &1.text) |> Enum.join("\n")

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

    test "a successful run surfaces stdout and is not an error" do
      {blocks, is_error} =
        ContentBlocks.from_runs([
          %{id: "run-1", status: "success", exit_code: 0, stdout: "v2.7.6", stderr: ""}
        ])

      assert text(blocks) =~ "v2.7.6"
      assert text(blocks) =~ "status=success"
      refute is_error
    end

    test "a non-zero exit flags isError even when status isn't a failure word" do
      {_blocks, is_error} =
        ContentBlocks.from_runs([%{id: "r", status: "success", exit_code: 1, stdout: ""}])

      assert is_error
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
end

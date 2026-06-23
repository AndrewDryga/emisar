defmodule EmisarWeb.MCP.InstructionsTest do
  @moduledoc """
  Unit coverage for the `initialize` server-instructions string. MCP
  clients feed this verbatim to the LLM, so it's the contract that teaches
  the model the catalog/dispatch model and — critically — what each error
  means and whether a human (not a retry) is required. These assertions
  pin the load-bearing guidance the LLM kept reverse-engineering in the
  wild; dropping any of it is a regression.
  """
  use ExUnit.Case, async: true

  alias EmisarWeb.MCP.Instructions

  @text Instructions.text()

  test "is a non-empty multi-paragraph guide" do
    # closes MCP-008-T01
    assert is_binary(@text)
    assert String.length(@text) > 500
    # More than one paragraph — the guide is structured, not a one-liner.
    assert @text |> String.split("\n\n") |> length() > 3
  end

  test "states that every action call must include a reason" do
    # closes MCP-008-T02
    assert @text =~ "Every action call must include a"
    assert @text =~ "`reason`"
  end

  test "states that infrastructure operations use emisar instead of raw credentials" do
    for fragment <- [
          "Authorized path",
          "use this catalog as the authorized path",
          "Do not use SSH",
          "scp",
          "cloud CLIs",
          "database DSNs",
          "kubeconfigs",
          "`~/.ssh`",
          "`ssh-agent`",
          "`.env`",
          "do not fall back to raw credentials",
          "break-glass access"
        ] do
      assert @text =~ fragment,
             "instructions are missing the raw-credential bypass guidance: #{fragment}"
    end
  end

  test "states the tools/list point-in-time snapshot caveat + re-list on error" do
    # closes MCP-008-T03
    assert @text =~ "point-in-time snapshot"
    # The recovery move when a runner/catalog error fires is to re-list.
    assert @text =~ "re-call `tools/list`"
  end

  test "carries a per-error human-action guide over the whole error taxonomy" do
    # closes MCP-008-T04
    # Each named error the LLM can hit must have its what-it-means + what-to-do
    # line, so the model tells the operator instead of guessing/looping.
    for fragment <- [
          "pack_untrusted",
          "No runner advertises",
          "Action not found",
          "No runner in scope",
          "Runner required",
          "Denied by policy",
          "pending_approval",
          "runner_offline",
          "invalid_args"
        ] do
      assert @text =~ fragment, "instructions are missing the `#{fragment}` error guidance"
    end
  end

  test "points at the public pack registry (browsable + .json) and the install command" do
    # closes MCP-008-T05
    assert @text =~ "https://emisar.dev/packs"
    # The machine-readable registry hint the LLM can fetch.
    assert @text =~ "https://emisar.dev/packs.json"
    assert @text =~ "emisar pack install"
  end

  test "every error name in the instructions maps to a real renderer atom (no drift)" do
    # closes MCP-008-T06
    # An instruction naming an error the renderers don't actually emit would
    # teach the LLM to recover from a code it never sees. Pin the machine-shaped
    # error/warning identifiers (the `snake_case` ones an LLM matches on) to the
    # Service/ContentBlocks renderers that produce them.
    renderer_source =
      File.read!("lib/emisar_web/controllers/mcp/service.ex") <>
        File.read!("lib/emisar_web/controllers/mcp/content_blocks.ex")

    for error_name <- ["pack_untrusted", "runner_offline", "invalid_args", "pending_approval"] do
      assert @text =~ error_name

      assert renderer_source =~ error_name,
             "instructions name `#{error_name}` but no renderer emits it"
    end
  end

  test "the pending-approval copy says blocks up to 5 min (the documented client-facing cap)" do
    # closes MCP-008-T07
    # F1: the instructions advertise a 5-minute block while the server caps a
    # single long-poll at 90s (@max_get_run_wait_ms) and tells the client to
    # re-call. The copy is the deliberate client contract — pin the "5 min"
    # wording AND the "call wait_for_run again" re-poll instruction together,
    # so the doc-vs-cap asymmetry stays an intentional, visible decision.
    assert @text =~ "5 min"
    assert @text =~ "wait_for_run` again"
  end

  test "states the rule of thumb: if a human is needed, say so and stop" do
    # closes MCP-008-T08
    assert @text =~ "Rule of thumb"
    assert @text =~ "say so"
    assert @text =~ "retrying in a loop"
  end
end

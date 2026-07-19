defmodule EmisarWeb.MCP.InstructionsTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.Instructions

  @text Instructions.text()

  test "teaches the fixed discovery and exact execution workflow" do
    for fragment <- [
          "twelve fixed API tools",
          "`list_packs`",
          "`find_actions`",
          "`get_action`",
          "`run_action`",
          "immutable `pack_ref`",
          "compatible runner refs",
          "nonblank `reason`"
        ] do
      assert @text =~ fragment, "missing fixed workflow guidance: #{fragment}"
    end
  end

  test "keeps Emisar authoritative instead of teaching credential bypasses" do
    for fragment <- [
          "authorized path",
          "Do not bypass",
          "SSH",
          "cloud CLIs",
          "database credentials",
          "kubeconfigs",
          "break-glass access",
          "This covers read-only inspection too: run status checks, log tails, process lists, and config reads through Emisar actions rather than opening a shell, so even harmless-looking reads stay scoped, redacted, and audited."
        ] do
      assert @text =~ fragment, "missing authorization guidance: #{fragment}"
    end
  end

  test "dispatches destructive and critical actions to Emisar's approval gate" do
    assert @text =~
             "Destructive and critical actions are also dispatched directly through Emisar: its policy will deny or require human approval."

    assert @text =~
             "A client may still apply its own confirmation UI; that confirmation does not replace Emisar authorization or approval."

    assert @text =~ "Dispatch the action through Emisar and relay its decision."
  end

  test "teaches typed recovery, lineage history, waits, and cancellation semantics" do
    for fragment <- [
          "`operation_id`",
          "`get_operation`",
          "never repeat the mutation",
          "`wait_for_run`",
          "cancellation never cancels infrastructure work",
          "`recent_runs`",
          "credential lineage",
          "`scope: \"account\"`"
        ] do
      assert @text =~ fragment, "missing recovery guidance: #{fragment}"
    end
  end

  test "teaches exact runbook refs and the draft boundary" do
    for fragment <- [
          "`list_runbooks`",
          "`get_runbook`",
          "restart-postgres@3",
          "`execute_runbook`",
          "`create_runbook_draft`",
          "never publishes or executes"
        ] do
      assert @text =~ fragment, "missing runbook guidance: #{fragment}"
    end
  end

  test "pins the security and retry taxonomy" do
    for fragment <- [
          "pending_approval",
          "60 seconds",
          "operation_conflict",
          "pack_untrusted",
          "descriptor_mismatch",
          "target_contract_changed",
          "signature_required",
          "invalid_attestation",
          "signed_runbook_unsupported",
          "not_allowed",
          "invalid_args"
        ] do
      assert @text =~ fragment, "missing error guidance: #{fragment}"
    end
  end

  test "points at the public pack registry and concrete install command" do
    assert @text =~ "https://emisar.dev/packs"
    assert @text =~ "https://emisar.dev/packs.json"
    assert @text =~ "emisar pack install"
    assert @text =~ "Never assume installation already happened"
  end
end

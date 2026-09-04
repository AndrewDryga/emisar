defmodule EmisarWeb.MCP.ValidationErrorTest do
  # async: false — the log tests raise the :emisar_web application log level,
  # which is a global Logger mutation.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias EmisarWeb.MCP.ValidationError

  test "builds only normalized bounded validation details with a derived kind" do
    details =
      ValidationError.details(
        stage: "attacker-stage",
        issues: [
          %{path: "$.secret[value]", code: "attacker-code"},
          ValidationError.issue([:args, "Port_Name"], :type)
        ]
      )

    assert details == %{
             schema_version: 1,
             stage: "arguments",
             kind: "schema",
             issues: [
               %{path: "$", code: "schema"},
               %{path: "$.args.Port_Name", code: "type"}
             ]
           }
  end

  test "derives the published kind from the first rendered issue's code" do
    for {code, kind} <- [
          {:required, "missing"},
          {:unknown_arg, "unknown"},
          {:format, "format"},
          {:min, "range"},
          {:max_length, "size"},
          {:allowed, "enum"},
          {:conflict, "conflict"}
        ] do
      details = ValidationError.details(issues: [ValidationError.issue([:field], code)])
      assert details.kind == kind
    end
  end

  test "accepts semantic versions and drops arbitrary labels" do
    assert ValidationError.safe_version(" 1.2.3-rc.1+build.4 ") == "1.2.3-rc.1+build.4"
    assert ValidationError.safe_version("sk_live_secret") == nil
    assert ValidationError.safe_version(String.duplicate("1", 100)) == nil
  end

  describe "log_dispatch_rejected/4" do
    setup do
      :ok = Logger.put_application_level(:emisar_web, :info)
      on_exit(fn -> Logger.delete_application_level(:emisar_web) end)
      %{conn: Plug.Test.conn(:post, "/api/mcp/rpc")}
    end

    test "logs the fixed reason with the identifiers the call carried", %{conn: conn} do
      pack_ref = "linux@1.0.0/sha256:" <> String.duplicate("a", 64)

      log =
        capture_log([level: :info], fn ->
          :ok =
            ValidationError.log_dispatch_rejected(conn, "run_action", "not_allowed",
              action_id: "linux.uptime",
              pack_ref: pack_ref
            )
        end)

      assert log =~ "mcp.dispatch_rejected"
      assert log =~ "mcp_dispatch_reject_reason=not_allowed"
      assert log =~ "mcp_action_id=linux.uptime"
      assert log =~ "mcp_pack_ref=#{pack_ref}"
      assert log =~ "mcp_tool=run_action"
      refute log =~ "mcp_runbook_ref"
    end

    test "collapses a reason outside the published vocabulary", %{conn: conn} do
      log =
        capture_log([level: :info], fn ->
          :ok = ValidationError.log_dispatch_rejected(conn, "run_action", "attacker reason")
        end)

      assert log =~ "mcp_dispatch_reject_reason=rejected"
      refute log =~ "attacker reason"
    end
  end
end

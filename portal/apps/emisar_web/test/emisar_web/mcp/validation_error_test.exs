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

    test "logs the fixed reason with grammar-checked identifiers", %{conn: conn} do
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
    end

    test "collapses an unlisted reason and drops off-grammar identifiers", %{conn: conn} do
      # Grammar-valid but past the published byte bound — dropped all the same.
      long_pack_ref = String.duplicate("a", 200) <> "@1/sha256:" <> String.duplicate("b", 64)

      log =
        capture_log([level: :info], fn ->
          :ok =
            ValidationError.log_dispatch_rejected(conn, "run_action", "attacker reason",
              action_id: "Not An Action; DROP TABLE runs",
              pack_ref: long_pack_ref
            )
        end)

      assert log =~ "mcp_dispatch_reject_reason=rejected"
      refute log =~ "mcp_action_id"
      refute log =~ "mcp_pack_ref"
      refute log =~ "attacker reason"
      refute log =~ "DROP TABLE"
      refute log =~ long_pack_ref
    end
  end
end

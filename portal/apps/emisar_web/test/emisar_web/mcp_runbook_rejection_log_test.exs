defmodule EmisarWeb.MCPRunbookRejectionLogTest do
  use EmisarWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias Emisar.{ApiKeys, Catalog, Runbooks}
  alias Emisar.Auth.Subject
  alias EmisarWeb.MCP.RunbookTools

  @hash "sha256:" <> String.duplicate("b", 64)

  setup %{conn: conn} do
    :ok = Logger.put_application_level(:emisar_web, :info)
    on_exit(fn -> Logger.delete_application_level(:emisar_web) end)

    account = Fixtures.Accounts.create_account()
    user = Fixtures.Users.create_user()

    _membership =
      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: user.id,
        role: "owner"
      )

    subject = Fixtures.Subjects.subject_for(user, account, role: :owner)
    {:ok, raw, key} = ApiKeys.create_key(%{name: "runbook-rejects", kind: :mcp}, subject)

    %{conn: authorize(conn, raw), account: account, subject: subject, key: key, raw: raw}
  end

  test "an availability reject logs only its fixed reason and safe runbook ref", %{
    conn: conn,
    account: account,
    subject: subject,
    raw: raw
  } do
    compatible = Fixtures.Runners.create_runner(account_id: account.id, group: "fleet")
    incompatible = Fixtures.Runners.create_runner(account_id: account.id, group: "fleet")

    observe_catalog!(compatible, [action()])
    observe_catalog!(incompatible, [])
    trust_all!(subject)

    _runbook =
      publish_runbook!(
        subject,
        "fleet-health",
        %{"selection" => "all", "refs" => ["group:fleet"]}
      )

    sentinel = "sentinel_DO_NOT_LOG_runbook_reason"

    log =
      capture_log([level: :info], fn ->
        result =
          call(conn, %{
            "runbook_ref" => "fleet-health@1",
            "reason" => sentinel
          })

        assert result["error"]["code"] == "pack_unavailable"
      end)

    assert length(String.split(log, "mcp.dispatch_rejected")) == 2
    assert log =~ "mcp_dispatch_reject_reason=target_contract_changed"
    assert log =~ "mcp_runbook_ref=fleet-health@1"
    assert log =~ "mcp_tool=execute_runbook"
    refute log =~ sentinel
    refute log =~ raw
  end

  test "an authorization reject logs only its fixed reason and safe runbook ref", %{
    conn: conn,
    account: account,
    key: key
  } do
    subject = Subject.for_api_key(key, account)
    conn = Plug.Conn.assign(conn, :current_subject, %{subject | permissions: MapSet.new()})
    sentinel = "sentinel_DO_NOT_LOG_unauthorized_reason"

    log =
      capture_log([level: :info], fn ->
        assert {:error, payload} =
                 RunbookTools.call(
                   conn,
                   "execute_runbook",
                   %{"runbook_ref" => "private-runbook@1", "reason" => sentinel},
                   "op_324NN9NMDZ1T76NARWCKM5A0D6"
                 )

        assert payload.error.code == "not_allowed"
      end)

    assert length(String.split(log, "mcp.dispatch_rejected")) == 2
    assert log =~ "mcp_dispatch_reject_reason=not_allowed"
    assert log =~ "mcp_runbook_ref=private-runbook@1"
    assert log =~ "mcp_tool=execute_runbook"
    refute log =~ sentinel
  end

  defp authorize(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp call(conn, arguments) do
    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{
        "name" => "execute_runbook",
        "arguments" => arguments
      }
    }

    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/mcp/rpc", Jason.encode!(body))
    |> json_response(200)
    |> get_in(["result", "structuredContent"])
  end

  defp observe_catalog!(runner, actions) do
    assert {:ok, _runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => runner.enforce_signatures,
               "packs" => %{"operations" => %{"version" => "1.0.0", "hash" => @hash}},
               "actions" => actions
             })
  end

  defp trust_all!(subject) do
    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _trusted} = Catalog.trust_pack_version(version.id, subject)
      end
    end)
  end

  defp publish_runbook!(subject, slug, selector) do
    {:ok, draft} =
      Runbooks.create_runbook(
        %{
          "title" => String.replace(slug, "-", " "),
          "name" => slug,
          "slug" => slug,
          "definition" => %{
            "schema_version" => 1,
            "context_markdown" => "Verify the selected fleet.",
            "inputs" => [],
            "stages" => [
              %{
                "id" => "inspect",
                "title" => "Inspect",
                "mode" => "parallel",
                "max_parallel" => 16,
                "steps" => [
                  %{
                    "id" => "check",
                    "pack" => %{"id" => "operations"},
                    "action" => "operations.health",
                    "targets" => selector,
                    "args" => %{},
                    "outputs" => [],
                    "success" => [],
                    "wait" => nil
                  }
                ]
              }
            ]
          }
        },
        subject
      )

    assert {:ok, published} = Runbooks.publish(draft, subject)
    published
  end

  defp action do
    %{
      "id" => "operations.health",
      "pack_id" => "operations",
      "title" => "Check health",
      "kind" => "exec",
      "risk" => "low",
      "summary" => "Checks service health.",
      "description" => "Checks service health.",
      "side_effects" => [],
      "args" => [],
      "examples" => [],
      "search_terms" => ["health"]
    }
  end
end

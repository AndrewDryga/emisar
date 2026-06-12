defmodule EmisarWeb.AuditDetailLiveTest do
  use EmisarWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Emisar.{Audit, RequestContext, Runs}

  test "an action_run event shows the runner under the subject, not as a device", %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Emisar.Fixtures.runner_fixture(%{
        account_id: account.id,
        name: "web-01",
        group: "frontend",
        runner_version: "0.7.4"
      })

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "net.http_probe",
        source: "mcp",
        args: %{}
      })

    # A policy.evaluated-shaped event (system actor, action_run subject) as
    # the runbook engine writes — stamped with the runner's connect UA, as it
    # was before the source fix, to prove the device line no longer surfaces
    # "Runner (Go)" for it.
    {:ok, event} =
      Audit.log(account.id, "policy.evaluated",
        actor_kind: "system",
        subject_kind: "action_run",
        subject_id: run.id,
        subject_label: run.action_id,
        context: %RequestContext{user_agent: "Go-http-client/1.1"}
      )

    {:ok, _lv, html} = live(conn, ~p"/app/audit/#{event.id}")

    # Runner is a subject property: name (group) version, linked to the runner.
    assert html =~ "runner: web-01 (frontend) 0.7.4"
    assert html =~ ~p"/app/runners/#{runner.id}"

    # The bare Go HTTP client UA is no longer rendered as a device.
    refute html =~ "Runner (Go)"
  end
end

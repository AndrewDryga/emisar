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

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # Runner is a subject property: name (group) version. The "runner:" label is
    # plain; only the name links to the runner. The subject's id renders too.
    assert html =~ "runner:"
    assert html =~ "web-01 (frontend) 0.7.4"
    assert html =~ ~p"/app/#{account}/runners/#{runner.id}"
    assert html =~ run.id

    # The bare Go HTTP client UA is no longer rendered as a device.
    refute html =~ "Runner (Go)"

    # The payload is copyable (the JSON <pre> is the copy target).
    assert html =~ ~s(id="audit-payload-json")
    assert html =~ ~s(data-copy="#audit-payload-json")
  end

  test "the actor card surfaces the sign-in method + 2FA state (provenance, not JSON)", %{
    conn: conn
  } do
    {conn, user, account} = register_and_log_in(conn)

    subject =
      Emisar.Fixtures.subject_for(user, account, role: :owner, auth_method: :sso, mfa: true)

    {:ok, event} = Audit.record(Audit.Events.account_updated(subject, account))

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    # "via SSO" with a 2FA badge — answerable at a glance, not buried in JSON.
    assert html =~ "via"
    assert html =~ "SSO"
    assert html =~ "2FA"
  end

  test ~S(a runner_version of "-" renders as no version, not a dangling dash), %{conn: conn} do
    {conn, _user, account} = register_and_log_in(conn)

    runner =
      Emisar.Fixtures.runner_fixture(%{
        account_id: account.id,
        name: "ci-bot-runner",
        group: "ci",
        runner_version: "-"
      })

    {:ok, run} =
      Runs.create_run(%{
        account_id: account.id,
        runner_id: runner.id,
        action_id: "ci.lint",
        source: "mcp",
        args: %{}
      })

    {:ok, event} =
      Audit.log(account.id, "policy.evaluated",
        actor_kind: "system",
        subject_kind: "action_run",
        subject_id: run.id,
        subject_label: run.action_id
      )

    {:ok, _lv, html} = live(conn, ~p"/app/#{account}/audit/#{event.id}")

    assert html =~ "ci-bot-runner (ci)"
    refute html =~ "ci-bot-runner (ci) -"
  end
end

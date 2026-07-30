defmodule EmisarWeb.RunbookRunLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Runbooks.RunbookExecution
  alias EmisarWeb.MCP.RunbookTools

  @hash "sha256:" <> String.duplicate("c", 64)

  setup %{conn: conn} do
    {conn, user, account} = register_and_log_in(conn)
    Fixtures.Policies.create_policy(account_id: account.id)
    %{conn: conn, user: user, account: account, subject: owner_subject(user, account)}
  end

  defp trusted_runner(account, subject, opts \\ []) do
    runner =
      Fixtures.Runners.create_runner(
        account_id: account.id,
        group: Keyword.get(opts, :group, "database")
      )

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.2", "hash" => @hash}},
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => Keyword.get(opts, :risk, "low"),
                   "summary" => "Reports uptime",
                   "description" => "Reports uptime",
                   "side_effects" => [],
                   "args" => Keyword.get(opts, :args, []),
                   "examples" => [],
                   "search_terms" => [],
                   "output_schema" => %{
                     "type" => "object",
                     "required" => ["ready"],
                     "properties" => %{"ready" => %{"type" => "boolean"}},
                     "additionalProperties" => false
                   }
                 }
               ]
             })

    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    :ok = Runners.subscribe_runner_transport(runner)
    runner
  end

  defp published_runbook(subject, runner, opts \\ []) do
    stages =
      [
        stage(
          "inspect",
          "Inspect",
          "parallel",
          2,
          "none",
          [step("inspect", runner.group, opts)]
        )
      ] ++
        if Keyword.get(opts, :approval_stage, false) do
          [
            stage(
              "change",
              "Apply change",
              "sequential",
              1,
              "required",
              [step("apply", runner.group)]
            )
          ]
        else
          []
        end

    inputs =
      if Keyword.get(opts, :sensitive_input, false) do
        [
          %{
            "id" => "token",
            "description" => "One-time incident token",
            "type" => "string",
            "required" => true,
            "sensitive" => true,
            "min_length" => 4
          }
        ]
      else
        []
      end

    title = "Fleet recovery #{System.unique_integer([:positive])}"

    assert {:ok, runbook} =
             Runbooks.create_runbook(
               %{
                 "title" => title,
                 "slug" => Emisar.Slug.slugify(title),
                 "definition" => %{
                   "schema_version" => 1,
                   "context_markdown" =>
                     "## Before you run\n\n- Confirm the incident.\n- Stop if scope changed.",
                   "inputs" => inputs,
                   "stages" => stages
                 }
               },
               subject
             )

    assert {:ok, published} = Runbooks.publish(runbook, subject)
    published
  end

  defp stage(id, title, mode, max_parallel, approval, steps) do
    %{
      "id" => id,
      "title" => title,
      "mode" => mode,
      "max_parallel" => max_parallel,
      "approval" => approval,
      "steps" => steps
    }
  end

  defp step(id, group, opts \\ []) do
    bindings =
      if Keyword.get(opts, :sensitive_input, false),
        do: %{"token" => %{"source" => "input", "ref" => "token"}},
        else: %{}

    outputs =
      if Keyword.get(opts, :extract_ready, false) do
        [
          %{
            "id" => "ready",
            "source" => "structured_output",
            "sensitive" => false,
            "extract" => %{"type" => "json_pointer", "expression" => "/ready"}
          }
        ]
      else
        []
      end

    success =
      if outputs == [],
        do: [],
        else: [%{"output" => "ready", "operator" => "equals", "value" => true}]

    %{
      "id" => id,
      "pack" => %{"id" => "linux-core", "requirement" => "~> 1.4.0"},
      "action" => "linux.uptime",
      "targets" => %{"kind" => "group", "refs" => [group]},
      "args" => bindings,
      "outputs" => outputs,
      "success" => success,
      "wait" =>
        if(Keyword.get(opts, :wait, false),
          do: %{"interval_seconds" => 10, "timeout_seconds" => 30, "max_attempts" => 3}
        )
    }
  end

  defp start(lv, inputs \\ %{}) do
    render_change(lv, "run_form_changed", %{
      "reason" => "Investigate incident INC-42",
      "inputs" => inputs
    })

    render_click(lv, "start", %{})
  end

  defp execution, do: Repo.one!(RunbookExecution)

  describe "authorization and current preflight" do
    test "a viewer cannot mount the dispatch surface", %{
      user: user,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      destination = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^destination, flash: flash}}} =
               build_conn()
               |> log_in_user(viewer)
               |> live(~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert flash["info"] == "Running a runbook needs an operator role or above."
      assert user.id != viewer.id
    end

    test "renders typed inputs and the exact current frozen plan", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      args = [
        %{
          "name" => "token",
          "type" => "string",
          "required" => true,
          "sensitive" => true
        }
      ]

      runner = trusted_runner(account, subject, args: args)

      runbook =
        published_runbook(subject, runner,
          sensitive_input: true,
          extract_ready: true
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert html =~ "One-time incident token"
      assert html =~ ~s(type="password")

      render_change(lv, "run_form_changed", %{
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => "secret-token"}
      })

      send(lv.pid, {:run_preflight, 2})
      html = render(lv)

      assert html =~ "Current preflight"
      assert html =~ "Inspect"
      assert html =~ "linux-core@1.4.2/#{@hash}"
      assert has_element?(lv, "#preflight-stage-inspect pre", "[REDACTED]")

      assert has_element?(
               lv,
               "#runbook-run-form[phx-submit=start] button[type=submit]:not([disabled])"
             )
    end
  end

  describe "durable staged results" do
    test "reloads the active execution and exposes its exact immutable item", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      html = start(lv)
      execution_id = execution().id

      assert_patch(
        lv,
        ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}"
      )

      assert html =~ "Execution in progress"
      assert html =~ "linux-core@1.4.2/#{@hash}"
      assert html =~ "1 attempt"
      assert html =~ "View raw action output"

      {:ok, _reloaded, reloaded_html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert reloaded_html =~ execution().id
      assert reloaded_html =~ "Execution in progress"
    end

    test "shows extracted outputs and success evidence after completion", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner, extract_ready: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)

      assert {:ok, _run} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => true}
               })

      html = render(lv)
      assert html =~ "Execution succeeded"
      assert html =~ "Extracted outputs"
      assert html =~ "Success evidence"
      assert html =~ "ready"
      assert html =~ "Output extraction"
      assert html =~ "Success condition"
      assert html =~ "passed"
      assert html =~ "Run again"

      assert {:ok, result} = Runbooks.fetch_execution_result(execution().id, subject)
      assert {:ok, projection} = RunbookTools.project_execution(result)
      assert projection.status == "succeeded"

      assert [
               %{
                 status: "succeeded",
                 items: [
                   %{
                     status: "succeeded",
                     outputs: [%{output_id: "ready", status: "extracted", value: true}],
                     conditions: [%{output: "ready", status: "passed"}]
                   }
                 ]
               }
             ] = projection.stages
    end

    test "a failed item explains the halt and no later stage starts", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner, approval_stage: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)
      assert {:ok, _run} = Fixtures.Runs.finish(run, %{"status" => "failed", "exit_code" => 1})

      html = render(lv)
      assert html =~ "Execution halted"
      assert html =~ "action_failed"
      assert html =~ "The action attempt did not succeed"
      assert html =~ "Apply change"
      assert html =~ "halted"
      assert [_only_run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)
    end

    test "an unmet condition during a wait is recoverable rather than terminal", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner, extract_ready: true, wait: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)

      assert {:ok, _run} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => false}
               })

      html = render(lv)
      assert html =~ "waiting"
      assert html =~ "not met"
      refute html =~ "Execution halted"
    end

    test "a required stage waits without inventing an ActionRun", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner, approval_stage: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)

      assert {:ok, _run} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => true}
               })

      assert {:ok, result} = Runbooks.fetch_execution_result(execution().id, subject)
      assert Enum.map(result.execution.stages, & &1.status) == [:succeeded, :awaiting_approval]

      send(lv.pid, {:runbook_execution_updated, execution().id})
      html = render(lv)
      assert html =~ "Apply change"
      assert html =~ "awaiting approval", html |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert html =~ "approval required"

      assert [_first_stage_only] =
               Runs.list_runs_for_runbook_execution(account.id, execution().id)

      assert [request] = Repo.all(Emisar.Approvals.Request)
      assert request.run_id == nil
      assert is_binary(request.runbook_execution_stage_id)

      assert has_element?(
               lv,
               ~s(a[href="/app/#{account.slug}/approvals/#{request.id}"]),
               "Open approval"
             )
    end

    test "cancellation is durable and the page can start over", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      html = render_click(lv, "cancel_execution", %{})
      assert html =~ "Execution cancelled"
      assert html =~ "Run again"

      html = render_click(lv, "run_again", %{})
      assert html =~ "Start execution"
      assert html =~ "Recent executions"
      assert html =~ execution().id
      refute html =~ "Execution cancelled"
    end
  end
end

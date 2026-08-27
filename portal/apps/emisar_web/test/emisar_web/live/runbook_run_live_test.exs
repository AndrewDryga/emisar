defmodule EmisarWeb.RunbookRunLiveTest do
  use EmisarWeb.ConnCase, async: true
  import EmisarWeb.MCPContractAssertions
  alias Emisar.{Catalog, Fixtures, Repo, Runbooks, Runners, Runs}
  alias Emisar.Runbooks.{ExecutionItem, RunbookExecution}
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

    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

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
          [step("inspect", runner.group, opts)]
        )
      ] ++
        if Keyword.get(opts, :second_stage, false) do
          [
            stage(
              "change",
              "Apply change",
              "sequential",
              1,
              [step("apply", runner.group, opts)]
            )
          ]
        else
          []
        end

    inputs =
      cond do
        Keyword.get(opts, :sensitive_input, false) ->
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

        Keyword.get(opts, :typed_input, false) ->
          [
            %{
              "id" => "window",
              "description" => "Observation window in seconds",
              "type" => "integer",
              "required" => true,
              "sensitive" => false,
              "default" => 30
            }
          ]

        true ->
          []
      end

    title = "Fleet recovery #{System.unique_integer([:positive])}"

    definition = %{
      "schema_version" => 1,
      "context_markdown" =>
        "## Before you run\n\n- Confirm the incident.\n- Stop if scope changed.",
      "inputs" => inputs,
      "stages" => stages
    }

    [
      account_id: subject.account.id,
      created_by_id: subject.actor.id,
      title: title,
      slug: Emisar.Slug.slugify(title),
      definition: definition
    ]
    |> Fixtures.Runbooks.create_runbook()
    |> Fixtures.Runbooks.publish_runbook()
  end

  defp stage(id, title, mode, max_parallel, steps) do
    Map.merge(
      %{"id" => id, "title" => title, "mode" => mode, "steps" => steps},
      if(mode == "parallel", do: %{"max_parallel" => max_parallel}, else: %{})
    )
  end

  defp step(id, group, opts) do
    bindings =
      cond do
        Keyword.get(opts, :sensitive_input, false) ->
          %{"token" => %{"source" => "input", "ref" => "token"}}

        Keyword.get(opts, :typed_input, false) ->
          %{"window" => %{"source" => "input", "ref" => "window"}}

        true ->
          %{}
      end

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
      "pack" => %{"id" => "linux-core"},
      "action" => "linux.uptime",
      "targets" => %{"selection" => "all", "refs" => ["group:" <> group]},
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

  # The console-started execution has no MCP operation, so a schema-valid
  # placeholder stands in for the id when checking the wire contract.
  defp wire_response(projection) do
    %{"ok" => true, "operation_id" => "op_01J0E11D8Q1W7SM4R5T3Y6V9PA", "execution" => projection}
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp assert_before(html, first, second) do
    assert :binary.match(html, first) < :binary.match(html, second)
  end

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

      assert flash["error"] == "Running a runbook needs an operator role or above."
      assert user.id != viewer.id
    end

    test "a never-published runbook sends the operator to the editor, not the run page", %{
      conn: conn,
      user: user,
      account: account
    } do
      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          title: "Half baked",
          slug: "half-baked"
        )

      assert runbook.live_version == nil

      destination = ~p"/app/#{account}/runbooks/#{runbook.id}/edit"
      result = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert {:error, {:live_redirect, %{to: ^destination}}} = result
      assert {:ok, _lv, html} = follow_redirect(result, conn)
      assert html =~ "Publish this runbook before running it."
      refute Repo.exists?(RunbookExecution)
    end

    # The redirect above returns from mount before any execution assign exists,
    # so terminate/2 then unsubscribes a socket that never subscribed. Matching a
    # nil VALUE missed the ABSENT key and crashed the view on its way out. The
    # operator still got their redirect, so it surfaced only as a logged crash —
    # and it is asserted HERE, on the callback, rather than through live/2:
    # terminate runs after live/2 returns, so a log-capturing test around the
    # navigation passes whether or not the bug is present.
    test "terminate/2 survives a socket that never subscribed", %{account: account} do
      # The shape mount leaves behind on a redirect: the account is assigned by
      # the auth hook, the execution assigns never are.
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_account: account}}

      refute Map.has_key?(socket.assigns, :subscribed_execution_id)
      assert EmisarWeb.RunbookRunLive.terminate(:shutdown, socket) == :ok
    end

    test "an exact draft-test execution has a labeled read-only detail route", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      published = published_runbook(subject, runner)
      base_sha = Runbooks.definition_digest(published.definition)
      attrs = %{"title" => published.title, "draft_definition" => published.definition}

      assert {:ok, runbook} = Runbooks.save_draft(published, attrs, base_sha, subject)

      assert {:ok, compiled} =
               Runbooks.Compiler.compile(
                 runbook.draft_definition,
                 %{},
                 Runbooks.new_target_selection_seed(),
                 subject
               )

      assert {:ok, result} =
               Runbooks.Scheduler.Creation.create_execution(
                 runbook,
                 compiled,
                 "Validate the unpublished change",
                 subject,
                 kind: :draft_test
               )

      execution_id = result.execution_id
      assert_receive {:cloud_to_runner, _generation, _payload}, 500

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")

      assert lv |> element("h1") |> render() =~ "Draft test"
      assert has_element?(lv, "h1 a", "Runbooks")
      assert has_element?(lv, "h1 a", runbook.title)
      assert html =~ "Validate the unpublished change"
      refute has_element?(lv, "a", "Run again")
      refute has_element?(lv, "button", "Start execution")
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
          extract_ready: true,
          second_stage: true
        )

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert html =~ "One-time incident token"
      assert html =~ ~s(type="password")

      assert lv |> element("h1") |> render() =~ "Run"
      assert has_element?(lv, "h1 a", "Runbooks")
      assert has_element?(lv, "h1 a", runbook.title)

      assert has_element?(
               lv,
               "#runbook-operator-context article.border:not([class*='bg-zinc'])"
             )

      assert has_element?(lv, "#current-runbook-plan")
      assert has_element?(lv, "#current-runbook-plan-summary")
      assert has_element?(lv, "#runbook-start-rail:not([class*='border-l'])")
      assert has_element?(lv, "#runbook-execution-history")

      assert_before(html, ~s(id="runbook-operator-context"), ~s(id="runbook-run-form"))
      assert_before(html, ~s(name="reason"), ~s(id="current-runbook-plan"))
      assert_before(html, ~s(id="current-runbook-plan"), ~s(id="start-runbook-button"))
      assert_before(html, ~s(id="runbook-before-starting"), ~s(id="current-runbook-plan-summary"))

      assert_before(
        html,
        ~s(id="current-runbook-plan-summary"),
        ~s(id="runbook-execution-history")
      )

      render_change(lv, "run_form_changed", %{
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => "secret-token"}
      })

      send(lv.pid, {:run_preflight, 2})
      html = render(lv)

      assert html =~ "Current plan"
      assert html =~ "Inspect"
      assert html =~ "Apply change"
      assert html =~ "token"
      assert html =~ "[REDACTED]"
      refute html =~ @hash
      assert has_element?(lv, ~s([data-steps-marker="parallel"] [data-icon="workflow.parallel"]))
      assert has_element?(lv, ~s([data-steps-marker="number"]), "1")

      # The plan names the resolved runner with no glyph in front of it, the same
      # target line the editor renders one state earlier.
      assert has_element?(lv, "#current-runbook-plan", runner.name)
      refute has_element?(lv, "#current-runbook-plan", "→")

      # The step id rides with the action it runs, as it does in the editor —
      # it is identity a later step binds to, not part of the target line.
      assert has_element?(lv, ~s(#current-runbook-plan span[class*="font-mono"]), "inspect")
      refute has_element?(lv, "#current-runbook-plan p", "inspect")

      assert has_element?(
               lv,
               "#runbook-run-form[phx-submit=start] button[type=submit]:not([disabled])"
             )
    end

    test "a live definition with no inputs key still renders its run form", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      legacy = Fixtures.Runbooks.drop_runbook_definition_key(runbook, "inputs")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{legacy.id}/run")

      assert html =~ "Start execution"
      assert has_element?(lv, "#runbook-run-form")
    end

    test "browser strings freeze as typed values and a bad one names its own field", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      args = [
        %{
          "name" => "window",
          "type" => "integer",
          "required" => true,
          "sensitive" => false
        }
      ]

      runner = trusted_runner(account, subject, args: args)
      runbook = published_runbook(subject, runner, typed_input: true)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      assert html =~ ~s(value="30")

      render_change(lv, "run_form_changed", %{
        "_target" => ["inputs", "window"],
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"window" => "45 seconds"}
      })

      send(lv.pid, {:run_preflight, 2})
      html = render(lv)
      assert html =~ "Enter a whole number."
      assert has_element?(lv, "#start-runbook-button[disabled]")

      render_change(lv, "run_form_changed", %{
        "_target" => ["inputs", "window"],
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"window" => "45"}
      })

      send(lv.pid, {:run_preflight, 3})
      refute render(lv) =~ "Enter a whole number."

      render_click(lv, "start", %{})

      assert Jason.decode!(Repo.one!(ExecutionItem).args_raw) == %{"window" => 45}
    end

    test "a hostile non-object input payload returns a bounded form error", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      render_change(lv, "run_form_changed", %{
        "_target" => ["inputs"],
        "reason" => "Investigate incident INC-42",
        "inputs" => "not-an-object"
      })

      html = render(lv)

      assert html =~ "Input values must be an object."
      assert has_element?(lv, "#start-runbook-button[disabled]")
    end

    test "untouched required inputs stay neutral until touched or submitted", %{
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
      runbook = published_runbook(subject, runner, sensitive_input: true)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      send(lv.pid, {:run_preflight, 1})
      html = render(lv)

      refute html =~ "Plan blocked"
      refute html =~ "Required input is missing."
      assert html =~ "The plan resolves once the required inputs above are filled in."
      assert html =~ "Waiting for the required inputs."
      assert html =~ "Fill in the required inputs to start this execution."
      assert has_element?(lv, "#start-runbook-button[disabled]")

      # Touching a DIFFERENT field keeps the unreached blank quiet.
      render_change(lv, "run_form_changed", %{
        "_target" => ["reason"],
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => ""}
      })

      send(lv.pid, {:run_preflight, 2})
      html = render(lv)
      refute html =~ "Plan blocked"
      assert html =~ "The plan resolves once the required inputs above are filled in."

      # Interacting with the field itself reveals its validation.
      render_change(lv, "run_form_changed", %{
        "_target" => ["inputs", "token"],
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => ""}
      })

      send(lv.pid, {:run_preflight, 3})
      html = render(lv)
      assert html =~ "Plan blocked"
      assert html =~ "Required input is missing."

      # A valid value resolves the plan and arms the start button.
      render_change(lv, "run_form_changed", %{
        "_target" => ["inputs", "token"],
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => "secret-token"}
      })

      send(lv.pid, {:run_preflight, 4})
      refute render(lv) =~ "Plan blocked"
      assert has_element?(lv, "#start-runbook-button:not([disabled])")
    end

    test "a runbook deleted after mount cannot dispatch from the stale page", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      Fixtures.Runbooks.mark_runbook_as_deleted(runbook)

      assert start(lv) =~ "The runbook did not start. Re-run preflight and try again."
      refute Repo.one(RunbookExecution)
    end
  end

  describe "durable staged results" do
    test "the execution URL reloads its exact item while /run starts fresh", %{
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

      assert html =~ "Started by"
      assert html =~ "Test User"
      assert html =~ "running"
      assert html =~ runner.name
      refute html =~ @hash
      refute html =~ "1 attempt"
      assert has_element?(lv, "[id^=execution-item-] a", "View")

      # One target line across all three surfaces: the step id rides with the
      # action, the runner name stands alone, and no glyph leads either.
      assert has_element?(lv, ~s([id^=execution-item-] span[class*="font-mono"]), "inspect")
      refute has_element?(lv, "[id^=execution-item-] p", "inspect")
      refute has_element?(lv, "[id^=execution-item-]", "→")

      {:ok, _reloaded, reloaded_html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")

      assert reloaded_html =~ "Investigate incident INC-42"
      assert reloaded_html =~ "Started by"
      refute reloaded_html =~ "A later stage starts only after"
      refute reloaded_html =~ "Recent executions"

      {:ok, _fresh, fresh_html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert fresh_html =~ "Start execution"
      assert fresh_html =~ "Investigate incident INC-42"
      refute fresh_html =~ "Started by"
    end

    test "an execution keeps the definition it ran after the runbook moves on", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      start(lv)
      execution_id = execution().id

      # The runbook row itself mutates on publish, so what ran has to come from
      # the execution's own snapshot.
      renamed = put_in(runbook.definition, ["stages", Access.at(0), "title"], "Inspect again")
      base_sha = Runbooks.definition_digest(runbook.definition)
      attrs = %{"title" => runbook.title, "draft_definition" => renamed}

      assert {:ok, edited} = Runbooks.save_draft(runbook, attrs, base_sha, subject)
      published = Fixtures.Runbooks.publish_runbook(edited)

      assert published.live_version == 2
      assert Repo.reload!(execution()).definition == runbook.definition

      {:ok, _reloaded, html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")

      assert html =~ "Inspect"
      refute html =~ "Inspect again"
      # The runbook row still owns identity and navigation.
      assert html =~ runbook.title
    end

    test "shows extracted outputs and success evidence after completion", %{
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
        published_runbook(subject, runner, extract_ready: true, sensitive_input: true)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv, %{"token" => "secret-token"})

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 stream: "stdout",
                 payload: %{"chunk" => "checking fleet\n"}
               })

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 2,
                 kind: "progress",
                 stream: "stderr",
                 payload: %{"chunk" => "<host unavailable>\n"}
               })

      assert {:ok, _run} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "executed_command" => "uptime --pretty --token [REDACTED]",
                 "executed_command_truncated" => true,
                 "structured_output" => %{"ready" => true}
               })

      html = render(lv)
      assert html =~ "1 of 1 succeeded"
      assert has_element?(lv, "[id$='-progress']", "1 of 1 succeeded")

      stage_header =
        lv
        |> element("#runbook-execution-result section[id^=execution-stage] > header")
        |> render()

      refute stage_header =~ "rounded-full"
      refute stage_header =~ "succeeded succeeded"
      assert html =~ "max-w-7xl"
      refute has_element?(lv, "details[id^=execution-item-]")
      refute has_element?(lv, "[data-role=item-disclosure]")
      refute has_element?(lv, "#runbook-execution-result", "Arguments")
      refute has_element?(lv, "#runbook-execution-result", "Command and output")
      assert has_element?(lv, "[id^=execution-item-] pre[aria-label='Command and output']")

      assert has_element?(
               lv,
               "#runbook-execution-result [data-steps-marker='parallel'] [data-icon='workflow.parallel']"
             )

      assert has_element?(lv, "[id^=execution-item-] a", "View")
      refute html =~ "View raw action output"
      assert html =~ "Extracted outputs"
      assert html =~ "Success evidence"
      assert html =~ "ready"
      assert html =~ "Output extraction"
      assert html =~ "Success condition"
      assert html =~ "passed"
      assert html =~ "$ "
      assert html =~ "uptime --pretty --token [REDACTED]"
      assert html =~ " …"
      refute html =~ "secret-token"
      assert html =~ "checking fleet"
      assert html =~ "&lt;host unavailable&gt;"
      assert html =~ "text-rose-300"
      assert html =~ "Run again"

      assert {:ok, result} = Runbooks.fetch_execution_result(execution().id, subject)
      assert {:ok, projection} = RunbookTools.project_execution(result, subject)
      assert projection.status == "succeeded"
      refute Map.has_key?(projection, :approval)
      refute Map.has_key?(projection, :wait_until)
      assert_valid_tool_result("execute_runbook", wire_response(projection))

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
      runbook = published_runbook(subject, runner, second_stage: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution().id)
      assert {:ok, _run} = Fixtures.Runs.finish(run, %{"status" => "failed", "exit_code" => 1})

      html = render(lv)
      assert html =~ "Execution halted"
      # Machine codes stay out of the page — the halt block carries the message.
      refute html =~ "action_failed"
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

    test "a policy-gated run waits once without inventing an ActionRun", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      _policy =
        Fixtures.Policies.create_policy(
          account_id: account.id,
          rules: %{
            "schema_version" => 2,
            "defaults" => %{
              "low" => "allow",
              "medium" => "allow",
              "high" => "require_approval",
              "critical" => "require_approval"
            },
            "overrides" => [],
            "approval" => %{"min_approvals" => 1, "allow_self_approval" => true}
          }
        )

      runner = trusted_runner(account, subject, risk: "high")
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)

      assert {:ok, result} = Runbooks.fetch_execution_result(execution().id, subject)
      assert result.execution.status == :pending_approval
      assert Enum.map(result.execution.stages, & &1.status) == [:pending]

      send(lv.pid, {:runbook_execution_updated, execution().id})
      html = render(lv)
      assert html =~ "awaiting approval"
      assert html =~ "Waiting on approval"
      assert html =~ runner.name
      refute has_element?(lv, "details[id^=execution-item-]")

      assert Runs.list_runs_for_runbook_execution(account.id, execution().id) == []

      assert [request] = Repo.all(Emisar.Approvals.Request)
      assert request.run_id == nil
      assert request.runbook_execution_id == execution().id

      assert has_element?(
               lv,
               ~s(a[href="/app/#{account.slug}/approvals/#{request.id}"]),
               "View approval"
             )

      # The MCP projection hands the model the same bounded approval object an
      # action run gets: the operator URL and hard expiry, nothing else.
      assert {:ok, projection} = RunbookTools.project_execution(result, subject)
      assert projection.blocking.code == "approval_required"

      assert projection.approval == %{
               request_id: request.id,
               url: "#{EmisarWeb.Endpoint.url()}/app/#{account.slug}/approvals/#{request.id}",
               expires_at: request.expires_at
             }

      assert projection.wait_until == request.expires_at
      assert projection.next.tool == "wait_for_run"
      assert_valid_tool_result("execute_runbook", wire_response(projection))
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

      assert has_element?(lv, "#cancel-runbook-execution[role=dialog][aria-modal=true]")

      assert has_element?(
               lv,
               "#cancel-runbook-execution-confirm[phx-disable-with='Cancelling…']",
               "Cancel execution"
             )

      assert has_element?(lv, "#cancel-runbook-execution", runbook.title)
      assert has_element?(lv, "#cancel-runbook-execution", "Queued actions will not start")
      refute render(lv) =~ "data-confirm"

      html = render_click(lv, "cancel_execution", %{})
      assert html =~ "Execution cancelled"
      assert html =~ "Run again"

      html = render_click(lv, "run_again", %{})
      assert html =~ "Start execution"
      assert html =~ "Recent executions"
      assert html =~ "Investigate incident INC-42"
      assert html =~ "by Test User"
      refute html =~ "Execution cancelled"
    end
  end
end

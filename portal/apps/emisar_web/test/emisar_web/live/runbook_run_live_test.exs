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
          Keyword.get(opts, :max_parallel, 2),
          Keyword.get(opts, :steps, [step("inspect", runner.group, opts)])
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

    resolve_preflight(lv)
    lv |> form("#runbook-run-form") |> render_submit()
  end

  defp resolve_preflight(lv) do
    generation = :sys.get_state(lv.pid).socket.assigns.preflight_generation
    send(lv.pid, {:run_preflight, generation})
    render(lv)
  end

  defp preview_id(lv) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(input[name="preview_id"]))
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp execution, do: Repo.one!(RunbookExecution)

  describe "reviewed Start" do
    test "untouched browser input markers do not block preview or Start", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      args = [%{"name" => "window", "type" => "integer", "required" => true}]
      runner = trusted_runner(account, subject, args: args)
      runbook = published_runbook(subject, runner, typed_input: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      params = %{
        "reason" => "Use the default observation window",
        "inputs" => %{"window" => "30", "_unused_window" => ""}
      }

      render_change(lv, "run_form_changed", params)
      resolve_preflight(lv)
      assert has_element?(lv, "#start-runbook-button:not([disabled])")
      render_click(lv, "start", Map.put(params, "preview_id", preview_id(lv)))
      assert execution().reason == params["reason"]
      assert Jason.decode!(Repo.one!(ExecutionItem).args_raw) == %{"window" => 30}
    end

    test "browser metadata cleanup still rejects undeclared input names", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      params = %{
        "reason" => "Unexpected input must not run",
        "inputs" => %{"unexpected" => "value", "_unused_unexpected" => ""}
      }

      html = render_change(lv, "run_form_changed", params)
      assert html =~ "Input is not declared by this runbook"
      assert has_element?(lv, "#start-runbook-button[disabled]")
      html = render_click(lv, "start", Map.put(params, "preview_id", preview_id(lv)))
      assert html =~ "Input is not declared by this runbook"
      refute Repo.exists?(RunbookExecution)
    end

    test "stale displayed receipts cannot start a newer ready preview", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      resolve_preflight(lv)
      previous_id = preview_id(lv)
      params = %{"reason" => "reviewed fleet", "inputs" => %{}}
      render_change(lv, "run_form_changed", params)
      resolve_preflight(lv)
      refute preview_id(lv) == previous_id

      render_click(lv, "start", Map.put(params, "preview_id", previous_id))
      assert has_element?(lv, "#runbook-review-notice", "Review the updated plan")
      refute Repo.exists?(RunbookExecution)
      lv |> form("#runbook-run-form") |> render_submit()
      assert execution().reason == params["reason"]
    end

    test "loading Start refreshes without dispatch and old preflight messages cannot replace its receipt",
         %{conn: conn, account: account, subject: subject} do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      params = %{"reason" => "reviewed fleet", "inputs" => %{}}
      render_click(lv, "start", params)
      refute Repo.exists?(RunbookExecution)
      receipt = preview_id(lv)
      assert receipt != ""
      send(lv.pid, {:run_preflight, 1})
      assert preview_id(lv) == receipt
      lv |> form("#runbook-run-form") |> render_submit()
      render_click(lv, "start", Map.put(params, "preview_id", receipt))
      send(lv.pid, {:run_preflight, 1})
      render(lv)
      assert Repo.aggregate(RunbookExecution, :count) == 1
    end

    test "changed targets require a second Start and preserve the submitted reason", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      params = %{"reason" => "reviewed fleet", "inputs" => %{}}
      render_change(lv, "run_form_changed", params)
      resolve_preflight(lv)
      trusted_runner(account, subject)
      lv |> form("#runbook-run-form") |> render_submit()
      refute Repo.exists?(RunbookExecution)
      refute Repo.exists?(Emisar.Approvals.Request)
      assert has_element?(lv, "#runbook-review-notice")
      assert render(lv) =~ params["reason"]
      lv |> form("#runbook-run-form") |> render_submit()
      assert execution().frozen_plan["total_items"] == 2
    end

    test "submit casts and preserves inputs that changed without a change event", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      args = [
        %{"name" => "window", "type" => "integer", "required" => true, "sensitive" => false}
      ]

      runner = trusted_runner(account, subject, args: args)
      runbook = published_runbook(subject, runner, typed_input: true)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      resolve_preflight(lv)

      params = %{
        "reason" => "longer observation",
        "inputs" => %{"window" => "60"},
        "preview_id" => preview_id(lv)
      }

      render_click(lv, "start", params)
      refute Repo.exists?(RunbookExecution)
      assert has_element?(lv, ~s(input[name="inputs[window]"][value="60"]))
      assert has_element?(lv, "#runbook-review-notice")
      lv |> form("#runbook-run-form") |> render_submit()
      assert Jason.decode!(Repo.one!(ExecutionItem).args_raw) == %{"window" => 60}
    end

    test "the displayed release remains pinned if a newer release is published", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      original = published_runbook(subject, runner)
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{original.id}/run")
      assert html =~ "Release 1."
      params = %{"reason" => "original procedure", "inputs" => %{}}
      render_change(lv, "run_form_changed", params)
      resolve_preflight(lv)

      attrs = %{
        "draft_definition" => Map.put(original.definition, "context_markdown", "New procedure")
      }

      digest = Runbooks.definition_digest(original.definition)
      assert {:ok, edited} = Runbooks.save_draft(original, attrs, digest, subject)
      assert Fixtures.Runbooks.publish_runbook(edited).live_version == 2
      lv |> form("#runbook-run-form") |> render_submit()
      assert execution().runbook_version == 1
      assert execution().definition == original.definition
    end
  end

  defp append_large_preview(run) do
    assert {:ok, _event} =
             Runs.append_event(run, %{
               seq: 1,
               kind: "progress",
               payload: %{"chunk" => run.id <> "\n" <> String.duplicate("🙂", 65_000)}
             })
  end

  defp flush_execution_reload(lv) do
    render(lv)

    case :sys.get_state(lv.pid).socket.assigns do
      %{subscribed_execution_id: id, execution_reload_timer: {token, timer}} ->
        Process.cancel_timer(timer)
        send(lv.pid, {:reload_execution, id, token})

      _assigns ->
        :ok
    end

    render(lv)
  end

  defp capture_queries(pid, fun) do
    owner = self()
    ref = make_ref()

    :ok =
      :telemetry.attach(
        ref,
        [:emisar, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == pid, do: send(owner, {ref, metadata.query, metadata.params})
        end,
        nil
      )

    try do
      fun.()
      drain_queries(ref)
    after
      :telemetry.detach(ref)
    end
  end

  defp drain_queries(ref) do
    receive do
      {^ref, query, params} -> [{query, params} | drain_queries(ref)]
    after
      0 -> []
    end
  end

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
    test "a viewer can read the runbook but cannot start it", %{
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

      assert {:ok, lv, html} =
               build_conn()
               |> log_in_user(viewer)
               |> live(~p"/app/#{account}/runbooks/#{runbook.id}/run")

      assert html =~ "Confirm the incident"
      assert has_element?(lv, "#runbook-read-only", "cannot start it")
      assert has_element?(lv, "#start-runbook-button[disabled]")
      render_click(lv, "start", %{"reason" => "Forged start", "inputs" => %{}})
      refute Repo.exists?(RunbookExecution)
      refute_receive {:dispatch_run, _, _}
    end

    test "scope refresh preserves inputs and the displayed plan until explicit recheck", %{
      conn: conn,
      user: user,
      account: account,
      subject: subject
    } do
      runner =
        trusted_runner(account, subject,
          args: [%{"name" => "window", "type" => "integer", "required" => true}]
        )

      runbook = published_runbook(subject, runner, typed_input: true)
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      membership = Fixtures.Memberships.force_role(membership, "admin")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")

      render_change(lv, "run_form_changed", %{
        "reason" => "Keep this reason",
        "inputs" => %{"window" => "45"}
      })

      resolve_preflight(lv)
      before = :sys.get_state(lv.pid).socket.assigns
      assert before.preflight.state == :ready
      receipt = preview_id(lv)

      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.none())
      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      assert render(lv) =~ "Your access changed"
      after_change = :sys.get_state(lv.pid).socket.assigns
      assert after_change.reason == before.reason
      assert after_change.input_raw == before.input_raw
      assert after_change.preflight.plan == before.preflight.plan
      assert after_change.review == nil
      send(lv.pid, {:run_preflight, before.preflight_generation})
      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.preflight == after_change.preflight
      assert has_element?(lv, "#recheck-runbook-plan")
      assert has_element?(lv, "#start-runbook-button[disabled]")

      render_click(lv, "start", %{
        "reason" => before.reason,
        "inputs" => %{"window" => "45"},
        "preview_id" => receipt
      })

      refute Repo.exists?(RunbookExecution)

      render_click(lv, "recheck_plan", %{})
      assert :sys.get_state(lv.pid).socket.assigns.preflight.state == :error
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      render(lv)
      assert has_element?(lv, "#start-runbook-button[disabled]")
      render_click(lv, "recheck_plan", %{})
      assert has_element?(lv, "#start-runbook-button:not([disabled])")
      assert preview_id(lv) != receipt
      assert :sys.get_state(lv.pid).socket.assigns.input_raw == before.input_raw
      refute Repo.exists?(RunbookExecution)
      refute_receive {:dispatch_run, _, _}
    end

    # The reason is copied onto the approval card and the audit trail, so the
    # domain rejects a bidi override rather than stripping it. The flash has to
    # name the field: the generic "re-run preflight and try again" sent the
    # operator round a loop that fails identically every time.
    test "a reason carrying a bidi override names the field to fix", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      send(lv.pid, {:run_preflight, 1})

      render_change(lv, "run_form_changed", %{
        "reason" => "release the \u202Ehctiws window",
        "inputs" => %{}
      })

      resolve_preflight(lv)
      lv |> form("#runbook-run-form") |> render_submit()

      assert render(lv) =~
               "The reason contains control or formatting characters. Use plain text and start again."

      refute Repo.exists?(RunbookExecution)
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

      assert has_element?(
               lv,
               "#runbook-execution-result",
               "This execution runs an unpublished workflow on your runners."
             )

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
      refute has_element?(lv, "#current-runbook-plan-summary")
      assert has_element?(lv, "#runbook-start-rail:not([class*='border-l'])")
      assert has_element?(lv, "#runbook-execution-history")

      assert_before(html, ~s(id="runbook-operator-context"), ~s(id="runbook-run-form"))
      assert_before(html, ~s(name="reason"), ~s(id="current-runbook-plan"))
      assert_before(html, ~s(id="current-runbook-plan"), ~s(id="start-runbook-button"))

      assert_before(
        html,
        ~s(id="runbook-before-starting"),
        ~s(id="runbook-execution-history")
      )

      render_change(lv, "run_form_changed", %{
        "reason" => "Investigate incident INC-42",
        "inputs" => %{"token" => "secret-token"}
      })

      send(lv.pid, {:run_preflight, 2})
      html = render(lv)

      refute html =~ "Plan summary"
      assert html =~ "Targets and policies are checked again when you start."
      refute html =~ "dispatched exactly as shown"
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

      lv |> form("#runbook-run-form") |> render_submit()

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
      assert html =~ "Enter the required inputs to preview the actions and target runners."

      assert has_element?(
               lv,
               "#current-runbook-plan > p.text-zinc-400",
               "Enter the required inputs"
             )

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
      assert html =~ "Enter the required inputs to preview the actions and target runners."

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

      assert start(lv) =~ "The runbook couldn&#39;t start. Refresh the page and try again."
      refute Repo.one(RunbookExecution)
    end
  end

  describe "durable staged results" do
    test "retained item outputs render without an action attempt", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)

      execution =
        Fixtures.Runbooks.create_execution_with_outputs(runbook, runner, [
          %{id: "inspection", value: "Retained result", sensitive: false}
        ])

      {:ok, lv, _html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution.id}")

      assert has_element?(lv, "#runbook-execution-result", "Retained result")
      refute has_element?(lv, "[id^=execution-item-] a", "View run")
      refute has_element?(lv, "[id^=execution-item-]", "Action result")
    end

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

      execution_id = execution().id
      :ok = Runbooks.subscribe_execution(account.id, execution_id)

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

      assert_receive {:runbook_execution_updated, ^execution_id}, 500
      html = flush_execution_reload(lv)
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
      assert html =~ "Result checks"
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
      execution_id = execution().id
      :ok = Runbooks.subscribe_execution(account.id, execution_id)
      assert {:ok, _run} = Fixtures.Runs.finish(run, %{"status" => "failed", "exit_code" => 1})

      assert_receive {:runbook_execution_updated, ^execution_id}, 500
      html = flush_execution_reload(lv)
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
      execution_id = execution().id
      :ok = Runbooks.subscribe_execution(account.id, execution_id)

      assert {:ok, _run} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => false}
               })

      assert_receive {:runbook_execution_updated, ^execution_id}, 500
      html = flush_execution_reload(lv)
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

      send(lv.pid, {:run_preflight, 1})
      assert has_element?(lv, "#current-runbook-plan > header", "Approval required")
      refute has_element?(lv, "#current-runbook-plan-summary")

      start(lv)

      assert {:ok, result} = Runbooks.fetch_execution_result(execution().id, subject)
      assert result.execution.status == :pending_approval
      assert Enum.map(result.execution.stages, & &1.status) == [:pending]

      send(lv.pid, {:runbook_execution_updated, execution().id})
      html = flush_execution_reload(lv)
      assert html =~ "awaiting approval"
      assert html =~ "Waiting for approval"

      assert has_element?(
               lv,
               "#runbook-execution-result",
               "This execution starts once all required approvals are received."
             )

      assert html =~ runner.name
      refute has_element?(lv, "details[id^=execution-item-]")

      assert Runs.list_runs_for_runbook_execution(account.id, execution().id) == []

      assert [request] = Repo.all(Emisar.Approvals.Request)
      assert request.run_id == nil
      assert request.runbook_execution_id == execution().id

      assert has_element?(
               lv,
               ~s(a[href="/app/#{account.slug}/approvals/#{request.id}"]),
               "Waiting for approval"
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

    test "coalesces exact execution bursts and unsubscribes after the terminal reload", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)
      execution_id = execution().id
      :ok = Runbooks.subscribe_execution(account.id, execution_id)
      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution_id)

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 payload: %{"chunk" => "latest evidence\n"}
               })

      Runbooks.broadcast_execution_updated(account.id, execution_id)
      assert_receive {:runbook_execution_updated, ^execution_id}, 500
      render(lv)
      assert {token, timer} = :sys.get_state(lv.pid).socket.assigns.execution_reload_timer
      Process.cancel_timer(timer)

      queries =
        capture_queries(lv.pid, fn ->
          for _index <- 1..50 do
            Runbooks.broadcast_execution_updated(account.id, execution_id)
            assert_receive {:runbook_execution_updated, ^execution_id}, 500
          end

          render(lv)
        end)

      assert queries == []
      assert {^token, ^timer} = :sys.get_state(lv.pid).socket.assigns.execution_reload_timer

      assert {:ok, _finished} =
               Fixtures.Runs.finish(run, %{
                 "status" => "success",
                 "structured_output" => %{"ready" => true}
               })

      assert_receive {:runbook_execution_updated, ^execution_id}, 500

      reload_queries =
        capture_queries(lv.pid, fn ->
          send(lv.pid, {:reload_execution, execution_id, token})
          assert render(lv) =~ "1 of 1 succeeded"
        end)

      assert Enum.count(reload_queries, fn {sql, _params} ->
               String.contains?(sql, ~s(FROM "runbook_executions"))
             end) == 1

      assert Enum.count(reload_queries, fn {sql, _params} ->
               String.contains?(sql, "LATERAL")
             end) == 1

      assert render(lv) =~ "latest evidence"
      assert :sys.get_state(lv.pid).socket.assigns.subscribed_execution_id == nil
      assert :sys.get_state(lv.pid).socket.assigns.execution_reload_timer == nil

      assert capture_queries(lv.pid, fn ->
               send(lv.pid, {:runbook_execution_updated, execution_id})
               send(lv.pid, {:reload_execution, execution_id, token})
               render(lv)
             end) == []
    end

    test "ignores unrelated updates and stale timers after navigation back to the same execution",
         %{
           conn: conn,
           account: account,
           subject: subject
         } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)
      execution_id = execution().id

      assert capture_queries(lv.pid, fn ->
               send(lv.pid, {:runbook_execution_updated, Repo.generate_id()})
               render(lv)
             end) == []

      send(lv.pid, {:runbook_execution_updated, execution_id})
      render(lv)
      assert {old_token, old_timer} = :sys.get_state(lv.pid).socket.assigns.execution_reload_timer

      render_patch(lv, ~p"/app/#{account}/runbooks/#{runbook.id}/run?new=true")
      assert :sys.get_state(lv.pid).socket.assigns.subscribed_execution_id == nil
      assert Process.read_timer(old_timer) == false

      render_patch(lv, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")
      send(lv.pid, {:runbook_execution_updated, execution_id})
      render(lv)
      assert {new_token, new_timer} = :sys.get_state(lv.pid).socket.assigns.execution_reload_timer
      Process.cancel_timer(new_timer)
      refute old_token == new_token

      assert capture_queries(lv.pid, fn ->
               send(lv.pid, {:reload_execution, execution_id, old_token})
               render(lv)
             end) == []

      assert {^new_token, ^new_timer} =
               :sys.get_state(lv.pid).socket.assigns.execution_reload_timer

      assert flush_execution_reload(lv) =~ "running"
    end

    test "a pending reload uses current read permissions and clears previously visible output", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)
      execution_id = execution().id
      assert [run] = Runs.list_runs_for_runbook_execution(account.id, execution_id)
      append_large_preview(run)
      send(lv.pid, {:runbook_execution_updated, execution_id})
      flush_execution_reload(lv)
      assert :sys.get_state(lv.pid).socket.assigns.events_by_attempt != %{}

      send(lv.pid, {:runbook_execution_updated, execution_id})
      render(lv)
      socket = :sys.get_state(lv.pid).socket
      assert {token, timer} = socket.assigns.execution_reload_timer
      Process.cancel_timer(timer)
      subject = Fixtures.Subjects.permissionless_subject(account)
      socket = Phoenix.Component.assign(socket, :current_subject, subject)

      assert capture_queries(self(), fn ->
               assert {:noreply, denied} =
                        EmisarWeb.RunbookRunLive.handle_info(
                          {:reload_execution, execution_id, token},
                          socket
                        )

               assert denied.assigns.result == nil
               assert denied.assigns.events_by_attempt == %{}
               assert denied.assigns.subscribed_execution_id == nil
               assert denied.assigns.execution_reload_timer == nil
               assert denied.assigns.flash["error"] == "This execution is no longer visible."

               assert denied.redirected ==
                        {:live, :redirect,
                         %{to: ~p"/app/#{account}/runbooks/#{runbook.id}/run", kind: :push}}
             end) == []
    end

    test "loads only visible attempt previews and drops hidden output on collapse", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      steps = Enum.map(1..26, &step("inspect-#{&1}", runner.group, []))
      runbook = published_runbook(subject, runner, steps: steps, max_parallel: 16)

      assert {:ok, %{execution_id: execution_id}} =
               Runbooks.dispatch_runbook(runbook, "Inspect preview bounds", subject)

      :ok = Runbooks.subscribe_execution(account.id, execution_id)
      initial_runs = Runs.list_runs_for_runbook_execution(account.id, execution_id)
      assert length(initial_runs) == 16
      Enum.each(initial_runs, &append_large_preview/1)

      for run <- Enum.take(initial_runs, 10) do
        assert {:ok, _finished} =
                 Fixtures.Runs.finish(run, %{
                   "status" => "success",
                   "structured_output" => %{"ready" => true}
                 })

        assert_receive {:runbook_execution_updated, ^execution_id}, 500
      end

      runs = Runs.list_runs_for_runbook_execution(account.id, execution_id)
      assert length(runs) == 26

      initial_ids = MapSet.new(initial_runs, & &1.id)

      runs
      |> Enum.reject(&MapSet.member?(initial_ids, &1.id))
      |> Enum.each(&append_large_preview/1)

      {:ok, lv, html} =
        live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert map_size(assigns.events_by_attempt) == 25
      [stage] = assigns.result.execution.stages
      hidden_item = List.last(assigns.result.execution.items)
      hidden_run = assigns.attempts_by_item[hidden_item.id]
      refute Map.has_key?(assigns.events_by_attempt, hidden_run.id)
      refute html =~ "execution-item-#{hidden_item.id}"
      assert html =~ "earlier output omitted"

      expanded_queries =
        capture_queries(lv.pid, fn ->
          render_click(lv, "toggle_execution_stage", %{"id" => stage.id})
        end)

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert map_size(assigns.events_by_attempt) == 26
      assert Map.has_key?(assigns.events_by_attempt, hidden_run.id)
      assert has_element?(lv, "#execution-item-#{hidden_item.id}")

      assert Enum.count(expanded_queries, fn {sql, _params} ->
               String.contains?(sql, "LATERAL")
             end) == 1

      collapsed_queries =
        capture_queries(lv.pid, fn ->
          render_click(lv, "toggle_execution_stage", %{"id" => stage.id})
        end)

      assert map_size(:sys.get_state(lv.pid).socket.assigns.events_by_attempt) == 25
      refute Map.has_key?(:sys.get_state(lv.pid).socket.assigns.events_by_attempt, hidden_run.id)
      refute has_element?(lv, "#execution-item-#{hidden_item.id}")
      hidden_id = Ecto.UUID.dump!(hidden_run.id)

      assert [{_sql, params}] =
               Enum.filter(collapsed_queries, fn {sql, _params} ->
                 String.contains?(sql, "LATERAL")
               end)

      refute hidden_id in List.flatten(params)
      refute hidden_run.id in List.flatten(params)
    end

    test "a viewer without action scope reads retained history after the parent and runner are deleted",
         %{
           account: account,
           subject: subject
         } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)

      assert {:ok, %{execution_id: execution_id}} =
               Runbooks.dispatch_runbook(runbook, "Retained incident evidence", subject)

      [run] = Runs.list_runs_for_runbook_execution(account.id, execution_id)

      assert {:ok, _event} =
               Runs.append_event(run, %{
                 seq: 1,
                 kind: "progress",
                 payload: %{"chunk" => "Retained output"}
               })

      Fixtures.Runbooks.mark_runbook_as_deleted(runbook)
      Fixtures.Runners.mark_deleted(runner)
      viewer = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: viewer.id,
          role: "viewer"
        )

      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.none())

      assert {:ok, lv, html} =
               build_conn()
               |> log_in_user(viewer)
               |> live(~p"/app/#{account}/runbooks/#{runbook.id}/runs/#{execution_id}")

      assert html =~ "Retained incident evidence"
      assert html =~ "Retained output"
      assert :sys.get_state(lv.pid).socket.assigns.runbook.deleted_at != nil
      assert has_element?(lv, "#cancel-runbook-execution-confirm[disabled]")
      render_click(lv, "cancel_execution", %{})
      assert Repo.reload!(execution()).status == :active
    end

    test "execution URLs reject a different runbook and a foreign account", %{
      conn: conn,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      runbook = published_runbook(subject, runner)
      other = published_runbook(subject, runner)

      assert {:ok, %{execution_id: execution_id}} =
               Runbooks.dispatch_runbook(runbook, "Exact history", subject)

      wrong_path = ~p"/app/#{account}/runbooks/#{other.id}/run"

      assert {:error, {:live_redirect, %{to: ^wrong_path}}} =
               live(conn, ~p"/app/#{account}/runbooks/#{other.id}/runs/#{execution_id}")

      {foreign_conn, _user, foreign_account} = register_and_log_in(build_conn())
      foreign_path = ~p"/app/#{foreign_account}/runbooks/#{runbook.id}/run"

      assert {:error, {:live_redirect, %{to: ^foreign_path}}} =
               live(
                 foreign_conn,
                 ~p"/app/#{foreign_account}/runbooks/#{runbook.id}/runs/#{execution_id}"
               )
    end

    test "scope loss disables whole-execution cancellation without dropping retained output", %{
      conn: conn,
      user: user,
      account: account,
      subject: subject
    } do
      runner = trusted_runner(account, subject)
      other = trusted_runner(account, subject, group: "other")

      runbook =
        published_runbook(subject, runner,
          steps: [step("first", runner.group, []), step("second", other.group, [])]
        )

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      membership = Fixtures.Memberships.force_role(membership, "admin")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/run")
      start(lv)
      before = :sys.get_state(lv.pid).socket.assigns
      assert has_element?(lv, "#cancel-runbook-execution-confirm:not([disabled])")

      Fixtures.Memberships.force_runner_access(membership, %Emisar.Accounts.RunnerAccess{
        mode: :restricted,
        groups: [],
        runner_ids: [runner.id],
        pack_mode: :all
      })

      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.result == before.result
      assert :sys.get_state(lv.pid).socket.assigns.events_by_attempt == before.events_by_attempt
      assert has_element?(lv, "#cancel-runbook-execution-confirm[disabled]")
      assert has_element?(lv, "#runbook-cancellation-access")
      render_click(lv, "cancel_execution", %{})
      assert execution().status == :active

      assert Enum.all?(
               Runs.list_runs_for_runbook_execution(account.id, execution().id),
               &(&1.status == :sent)
             )

      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      render(lv)
      assert has_element?(lv, "#cancel-runbook-execution-confirm:not([disabled])")
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

      assert has_element?(
               lv,
               "#cancel-runbook-execution",
               "Queued actions won't start. Running actions receive a cancellation request."
             )

      assert has_element?(lv, "#cancel-runbook-execution-confirm", "Cancel execution")
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

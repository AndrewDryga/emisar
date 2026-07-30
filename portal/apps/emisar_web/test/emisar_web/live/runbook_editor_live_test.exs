defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Catalog, Fixtures, Repo, Runbooks}
  alias Emisar.Runbooks.Runbook
  alias EmisarWeb.RunbookDraft

  defp valid_draft(attrs \\ %{}) do
    attrs = Map.new(attrs)

    RunbookDraft.new()
    |> Map.merge(%{
      "title" => attrs[:title] || "Fleet health",
      "slug" => attrs[:slug] || "fleet-health",
      "description" => "Inspect the current fleet.",
      "context_markdown" => "## Before you run\n\nConfirm the incident scope.",
      "inputs" => Map.get(attrs, :inputs, []),
      "stages" => [
        %{
          "id" => "inspect",
          "title" => "Inspect",
          "mode" => "parallel",
          "max_parallel" => "4",
          "steps" => [
            %{
              "id" => "uptime",
              "pack_id" => "linux-core",
              "action" => "linux.uptime",
              "target_refs" => ["group:" <> (attrs[:group] || "default")],
              "args" => [],
              "outputs" => [],
              "success" => [],
              "wait" => %{
                "enabled" => "false",
                "interval_seconds" => "10",
                "timeout_seconds" => "120",
                "max_attempts" => "12"
              }
            }
          ]
        }
      ]
    })
  end

  defp change(lv, draft, target \\ ["draft", "title"]) do
    render_change(lv, "draft_changed", %{
      "_target" => target,
      "draft" => form_params(draft)
    })
  end

  defp form_params(draft) do
    Map.update!(draft, "inputs", &indexed/1)
    |> Map.update!("stages", fn stages ->
      stages
      |> Enum.map(fn stage ->
        Map.update!(stage, "steps", fn steps ->
          steps
          |> Enum.map(fn step ->
            step
            |> Map.update!("args", &indexed/1)
            |> Map.update!("outputs", &indexed/1)
            |> Map.update!("success", &indexed/1)
          end)
          |> indexed()
        end)
      end)
      |> indexed()
    end)
  end

  defp indexed(values),
    do: values |> Enum.with_index() |> Map.new(fn {value, index} -> {to_string(index), value} end)

  defp arrange_current_action(account, user, opts \\ []) do
    runner = Fixtures.Runners.create_runner(account_id: account.id)
    hash = Fixtures.Catalog.pack_hash("linux-core-1.4.3")

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => "1.4.3", "hash" => hash}},
               "actions" => [
                 %{
                   "id" => "linux.uptime",
                   "pack_id" => "linux-core",
                   "title" => "Uptime",
                   "kind" => "exec",
                   "risk" => "low",
                   "summary" => "Reports uptime",
                   "description" => "Reports uptime",
                   "side_effects" => [],
                   "args" => Keyword.get(opts, :args, []),
                   "examples" => [],
                   "search_terms" => []
                 }
               ]
             })

    subject = owner_subject(user, account)
    {:ok, versions} = Catalog.list_all_pack_versions_for_account(subject)

    Enum.each(versions, fn version ->
      if version.trust_state != :trusted do
        assert {:ok, _version} = Catalog.trust_pack_version(version.id, subject)
      end
    end)

    Fixtures.Policies.create_policy(account_id: account.id)
    runner
  end

  describe "structured authoring" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      %{conn: conn, user: user, account: account}
    end

    test "exposes the complete v1 model without a raw definition editor", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")

      assert html =~ "Operator context"
      assert html =~ "Run-time inputs"
      assert html =~ "A stage is a barrier"
      assert html =~ "Arguments"
      assert html =~ "Extracted outputs"
      assert html =~ "Success conditions"
      assert html =~ "Retry policy"
      assert html =~ "Build the first stage"
      assert html =~ "Choose runners first"
      refute html =~ "definition issues"
      refute html =~ "steps_json"
      refute html =~ "definition_json"
      refute has_element?(lv, ~s(input[name="draft[stages][0][max_parallel]"]))

      assert has_element?(lv, "#runbook-stage-0")

      assert has_element?(
               lv,
               ~s(select[name="draft[stages][0][steps][0][target_candidate]"])
             )

      render_click(lv, "add_stage", %{})
      assert has_element?(lv, "#runbook-stage-1")
      assert has_element?(lv, "#runbook-stages button", "Add stage")

      staged_html = render(lv)
      add_stage_position = staged_html |> :binary.matches("Add stage") |> List.last()

      assert :binary.match(staged_html, ~s(id="runbook-stage-1")) < add_stage_position

      render_click(lv, "add_step", %{"stage" => "0"})
      assert has_element?(lv, "#runbook-stage-0-step-1")

      html = change(lv, valid_draft())
      assert html =~ "Maximum concurrent actions"
      assert has_element?(lv, ~s(input[name="draft[stages][0][max_parallel]"]))
      assert has_element?(lv, "button", "Stage identifier")
      assert has_element?(lv, "section", "Details")

      assert :binary.match(html, "Operator context") <
               :binary.match(html, ~s(id="runbook-inputs"))

      assert :binary.match(html, ~s(id="runbook-inputs")) <
               :binary.match(html, ~s(id="runbook-stages"))

      assert :binary.match(html, ~s(id="runbook-stages")) < :binary.match(html, "Details")

      assert :binary.match(html, ~s(name="draft[stages][0][steps][0][target_candidate]")) <
               :binary.match(html, ~s(name="draft[stages][0][steps][0][action_choice]"))
    end

    test "switching an input to enum opens stable add and remove controls", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      enum_input =
        RunbookDraft.input()
        |> Map.put("id", "environment")
        |> Map.put("type", "enum")

      html =
        change(
          lv,
          valid_draft(inputs: [enum_input]),
          ["draft", "inputs", "0", "type"]
        )

      assert html =~ "Allowed values"

      assert has_element?(
               lv,
               ~s(button[aria-expanded="true"]),
               "Default and constraints"
             )

      render_click(lv, "add_enum_value", %{"index" => "0"})

      assert has_element?(
               lv,
               ~s(input[name="draft[inputs][0][enum_values][0][value]"])
             )

      assert has_element?(lv, ~s(button[aria-label="Remove allowed value"]))

      render_click(lv, "remove_enum_value", %{"input" => "0", "value" => "0"})
      refute has_element?(lv, ~s(input[name="draft[inputs][0][enum_values][0][value]"]))
      assert has_element?(lv, ~s(button[aria-expanded="true"]))
    end

    test "success conditions require an output and start without a quoted empty value", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      change(lv, valid_draft())

      assert has_element?(lv, "button[disabled]", "Add condition")

      render_click(lv, "add_success", %{"stage" => "0", "step" => "0"})
      assert render(lv) =~ "Add an extracted output first."
      refute has_element?(lv, ~s(input[aria-label="Condition 1 JSON value"]))

      render_click(lv, "add_output", %{"stage" => "0", "step" => "0"})
      assert has_element?(lv, "button:not([disabled])", "Add condition")
      render_click(lv, "add_success", %{"stage" => "0", "step" => "0"})

      assert has_element?(
               lv,
               ~s(input[aria-label="Condition 1 JSON value"][value=""])
             )

      refute has_element?(
               lv,
               ~s(input[aria-label="Condition 1 JSON value"][value="\\"\\""])
             )
    end

    test "target-first action selection derives the pack from current runner support", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft =
        valid_draft()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "pack_id"], "")
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "action"], "")

      html =
        change(
          lv,
          draft,
          ["draft", "stages", "0", "steps", "0", "action_choice"]
        )

      assert html =~ "linux-core"
      refute html =~ "Version requirement"

      assert has_element?(
               lv,
               ~s(select[name="draft[stages][0][steps][0][action_choice]"] option[value="linux-core|linux.uptime"])
             )
    end

    test "target-first action selection renders descriptor-owned typed bindings", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user,
        args: [
          %{"name" => "path", "type" => "path", "required" => true, "sensitive" => false},
          %{"name" => "retries", "type" => "integer", "required" => false, "sensitive" => false},
          %{"name" => "token", "type" => "string", "required" => true, "sensitive" => true}
        ]
      )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      html = change(lv, valid_draft())

      assert html =~ "path · path"
      assert html =~ "retries · integer · optional"
      assert html =~ "token · string"
      refute has_element?(lv, "datalist#runbook-actions")

      assert has_element?(
               lv,
               ~s(select[name="draft[stages][0][steps][0][action_choice]"])
             )

      assert has_element?(
               lv,
               ~s(input[type=hidden][name="draft[stages][0][steps][0][args][0][name]"][value=path])
             )

      assert has_element?(
               lv,
               ~s(select[name="draft[stages][0][steps][0][args][1][source]"] option[value=omit])
             )

      refute has_element?(
               lv,
               ~s(select[name="draft[stages][0][steps][0][args][2][source]"] option[value=literal])
             )
    end

    test "saves exactly the canonical structured definition", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      draft = valid_draft()

      change(lv, draft)

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{} = runbook = Repo.one!(Runbook)
      assert runbook.status == :draft
      assert runbook.definition == RunbookDraft.definition(draft)

      assert get_in(runbook.definition, ["stages", Access.at(0), "steps", Access.at(0), "pack"]) ==
               %{"id" => "linux-core"}

      refute Map.has_key?(runbook.definition, "steps")
    end

    test "publishing is gated by the real current-state preflight", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      html = change(lv, valid_draft())
      assert html =~ "Checking runners, packs, trust, and policy"
      refute has_element?(lv, "button:not([disabled])", "Publish")

      send(lv.pid, {:runbook_preview, 1})
      html = render(lv)

      assert html =~ "Ready to publish", html |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert html =~ "1"
      assert has_element?(lv, "button:not([disabled])", "Publish")

      destination = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^destination}}} =
               render_click(lv, "publish", %{})

      assert Repo.one!(Runbook).status == :published
    end

    test "saves incomplete work as a draft while strict validation blocks publication", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      assert html =~ "Build the first stage"
      assert has_element?(lv, "button[disabled]", "Save draft")

      input =
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "count",
          "description" => "Number of observations",
          "type" => "integer",
          "default" => "wrong"
        })

      html = change(lv, valid_draft(inputs: [input]))

      assert html =~ "Input 1 · Default"
      assert has_element?(lv, "button:not([disabled])", "Save draft")
      assert has_element?(lv, "button[disabled]", "Publish")

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{status: :draft} = Repo.one!(Runbook)
    end

    test "metadata feedback follows the field the operator changed", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft = valid_draft(title: "")
      html = change(lv, draft, ["draft", "title"])

      assert html =~ "can&#39;t be blank"
      refute html =~ "has invalid format"
    end

    test "a viewer inspects the same structured definition without mutation controls", %{
      user: owner,
      account: account
    } do
      subject = owner_subject(owner, account)

      {:ok, runbook} =
        Runbooks.create_runbook(
          %{
            "title" => "Fleet health",
            "slug" => "fleet-health",
            "definition" => valid_draft() |> RunbookDraft.definition()
          },
          subject
        )

      viewer = Fixtures.Users.create_user()

      Fixtures.Memberships.create_membership(
        account_id: account.id,
        user_id: viewer.id,
        role: "viewer"
      )

      {:ok, lv, html} =
        build_conn()
        |> log_in_user(viewer)
        |> live(~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      assert html =~ "Read-only runbook"
      assert html =~ "Inspect"
      assert html =~ "linux.uptime"
      assert has_element?(lv, "#runbook-editor-form input[disabled]")
      refute has_element?(lv, "button", "Save draft")
      refute has_element?(lv, "#delete-runbook")
    end
  end

  describe "resource isolation" do
    test "cross-account and malformed identifiers are indistinguishable", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn)
      other = Fixtures.Runbooks.create_runbook()
      destination = ~p"/app/#{account}/runbooks"

      for id <- [other.id, "not-a-uuid"] do
        assert {:error, {:live_redirect, %{to: ^destination}}} =
                 live(conn, ~p"/app/#{account}/runbooks/#{id}/edit")
      end
    end
  end
end

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
              "target_selection" => "all",
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

  defp canonical_definition(draft),
    do: draft |> RunbookDraft.command() |> Runbooks.Authoring.build_v1()

  defp change(lv, draft, target \\ ["draft", "title"]) do
    render_change(lv, "draft_changed", %{
      "_target" => target,
      "draft" => form_params(draft)
    })
  end

  defp form_params(draft) do
    Map.update!(draft, "inputs", fn inputs ->
      inputs
      |> Enum.map(&Map.update!(&1, "enum_values", fn values -> indexed(values) end))
      |> indexed()
    end)
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
      assert html =~ "Wait policy"
      assert html =~ "Build the first stage"
      refute html =~ "Choose runners first"
      refute html =~ "Pack selection follows the action automatically"
      refute html =~ "definition issues"
      refute html =~ "steps_json"
      refute html =~ "definition_json"
      refute has_element?(lv, ~s(input[name="draft[stages][0][max_parallel]"]))
      assert html =~ "xl:grid-cols-[9rem_minmax(0,1fr)_10rem_11rem]"

      assert has_element?(lv, "#runbook-stage-0")
      assert has_element?(lv, "#runbook-stage-0-step-0-arguments")
      assert has_element?(lv, "#runbook-stage-0-step-0-outputs")
      assert has_element?(lv, "#runbook-stage-0-step-0-success")
      assert has_element?(lv, "#runbook-stage-0-step-0-wait")

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger[aria-disabled=\"true\"]",
               "No online runners available"
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-overview input[name="draft[stages][0][steps][0][id]"])
             )

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-overview[class~="xl:items-end"]|
             )

      refute has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-overview[class~="xl:items-start"]|
             )

      refute has_element?(lv, "button", "Step identifier")

      assert has_element?(lv, ~s(#runbook-inputs button[phx-click="add_input"]), "Add input")
      refute has_element?(lv, "a", "Cancel editing")

      render_click(lv, "add_input", %{})
      input_html = render(lv)

      assert :binary.match(input_html, ~s(id="runbook-input-0")) <
               :binary.match(input_html, ~s(phx-click="add_input"))

      assert has_element?(lv, "#runbook-input-0 h3", "Input 1")
      assert has_element?(lv, "#runbook-inputs > .max-w-5xl", "Add input")
      assert has_element?(lv, "#runbook-input-0 > .mt-6.space-y-6")
      refute has_element?(lv, "#runbook-input-0 .max-w-3xl")

      render_click(lv, "add_stage", %{})
      assert has_element?(lv, "#runbook-stage-1")
      assert has_element?(lv, "#runbook-stages button", "Add stage")

      staged_html = render(lv)
      add_stage_position = staged_html |> :binary.matches("Add stage") |> List.last()

      assert :binary.match(staged_html, ~s(id="runbook-stage-1")) < add_stage_position

      render_click(lv, "add_step", %{"stage" => "0"})
      assert has_element?(lv, "#runbook-stage-0-step-1")

      html = change(lv, valid_draft())
      assert html =~ "Maximum concurrency"
      assert has_element?(lv, ~s(input[name="draft[stages][0][max_parallel]"]))
      assert html =~ "xl:grid-cols-[9rem_minmax(0,1fr)_10rem_11rem]"

      assert has_element?(
               lv,
               "#runbook-inputs",
               "Yes - masked in plans, approvals, and results."
             )

      refute html =~ "Sensitive values are never shown"

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-overview input[name="draft[stages][0][id]"])
             )

      refute has_element?(lv, "button", "Stage identifier")
      refute html =~ "Caps fan-out within this stage."
      assert has_element?(lv, "section", "Details")
      refute html =~ "The description appears in runbook discovery for operators and LLMs."
      refute has_element?(lv, "#runbook-actions-desktop h2", "Actions")
      refute has_element?(lv, "#runbook-actions-mobile h2", "Actions")
      assert has_element?(lv, "#runbook-actions-desktop + section", "Publish check")

      assert :binary.match(html, ~s(name="draft[stages][0][id]")) <
               :binary.match(html, ~s(name="draft[stages][0][title]"))

      assert :binary.match(html, ~s(name="draft[stages][0][title]")) <
               :binary.match(html, ~s(name="draft[stages][0][mode]"))

      assert :binary.match(html, ~s(name="draft[stages][0][mode]")) <
               :binary.match(html, ~s(name="draft[stages][0][max_parallel]"))

      assert :binary.match(html, ~s(name="draft[stages][0][steps][0][id]")) <
               :binary.match(html, ~s(id="runbook-stage-0-step-0-targets"))

      assert :binary.match(
               html,
               ~s(id="runbook-stage-0-step-0-targets")
             ) <
               :binary.match(
                 html,
                 ~s(name="draft[stages][0][steps][0][action_choice]")
               )

      refute html =~ "file · json · optional"
      refute html =~ "Not sent to the action."

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][action_choice]"][value="linux-core|linux.uptime"])
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-overview button[data-combobox-trigger][disabled]),
               "linux.uptime"
             )

      assert html =~ ~s(data-value="linux-core|linux.uptime")

      refute html =~ "Unavailable · linux.uptime"
      refute html =~ "This action is not available on every selected runner."

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · all · 1 unavailable"
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_all"][phx-click="remove_target"][phx-value-target="group:default"][phx-value-selection="all"]),
               "default group Saved group is no longer available Unavailable"
             )

      refute has_element?(lv, "#runbook-stage-0-step-0-targets > .mt-2.space-y-2")

      assert :binary.match(html, "Operator context") <
               :binary.match(html, ~s(id="runbook-inputs"))

      assert :binary.match(html, ~s(id="runbook-inputs")) <
               :binary.match(html, ~s(id="runbook-stages"))

      assert :binary.match(html, ~s(id="runbook-stages")) < :binary.match(html, "Details")

      assert :binary.match(html, ~s(id="runbook-stage-0-step-0-targets")) <
               :binary.match(html, ~s(name="draft[stages][0][steps][0][action_choice]"))
    end

    test "switching an input to enum shows stable ordered controls", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      enum_input =
        RunbookDraft.input()
        |> Map.put("id", "environment")
        |> Map.put("type", "enum")
        |> Map.put("enum_values", [
          RunbookDraft.enum_value("staging"),
          RunbookDraft.enum_value("production")
        ])

      html =
        change(
          lv,
          valid_draft(inputs: [enum_input]),
          ["draft", "inputs", "0", "type"]
        )

      assert html =~ "Allowed values"
      assert html =~ "Sensitive"
      refute html =~ "Sensitive?"
      assert has_element?(lv, "#runbook-input-0 h3", "environment")
      assert has_element?(lv, "#runbook-input-0", "Input 1 · Enum")
      refute has_element?(lv, ~s([name="draft[inputs][0][default]"]))
      refute has_element?(lv, "#runbook-input-0 button", "Default and constraints")
      refute html =~ "Default and constraints"
      refute html =~ "input-constraints-0"
      refute html =~ "Behavior"
      refute html =~ "max-w-[39rem]"
      assert html =~ "sm:grid-cols-[minmax(0,1fr)_9rem_9rem]"
      assert html =~ "sm:items-end"

      required_name = "draft[inputs][0][required]"
      sensitive_name = "draft[inputs][0][sensitive]"

      for qualifier_name <- [required_name, sensitive_name] do
        assert has_element?(
                 lv,
                 ~s|input[type="hidden"][name="#{qualifier_name}"][value="false"]|
               )

        refute has_element?(lv, ~s|select[name="#{qualifier_name}"]|)
      end

      assert has_element?(
               lv,
               ~s|input[type="checkbox"][name="#{required_name}"][value="true"][checked]|
             )

      assert has_element?(
               lv,
               ~s|input[type="checkbox"][name="#{sensitive_name}"][value="true"]:not([checked])|
             )

      assert has_element?(
               lv,
               "#runbook-input-0 label",
               "Required"
             )

      assert has_element?(
               lv,
               "#runbook-input-0 label",
               "Sensitive"
             )

      assert has_element?(
               lv,
               ~s|input[name="draft[inputs][0][id]"][class~="font-mono"]:not([class~="text-xs"])|
             )

      assert :binary.match(html, ~s(name="draft[inputs][0][type]")) <
               :binary.match(html, ~s(name="draft[inputs][0][required]"))

      assert :binary.match(html, ~s(name="draft[inputs][0][required]")) <
               :binary.match(html, ~s(name="draft[inputs][0][sensitive]"))

      assert :binary.match(html, ~s(name="draft[inputs][0][sensitive]")) <
               :binary.match(html, "Allowed values")

      assert has_element?(
               lv,
               ~s(button[aria-label="Use as default: staging"][aria-pressed="false"])
             )

      lv
      |> element(~s(button[aria-label="Use as default: production"]))
      |> render_click()

      assert has_element?(
               lv,
               ~s(button[aria-label="Remove default: production"][aria-pressed="true"])
             )

      assert has_element?(
               lv,
               ~s(button[aria-pressed="true"][class*="bg-white/"][class*="ring-white/25"])
             )

      assert has_element?(
               lv,
               ~s(button[aria-pressed="true"] span[class*="ring-zinc-300"] span[class*="bg-zinc-200"])
             )

      refute has_element?(lv, ~s(button[aria-pressed="true"][class*="brand-"]))
      refute has_element?(lv, ~s(button[aria-pressed="true"] [class*="brand-"]))

      assert has_element?(
               lv,
               ~s(input[name="draft[inputs][0][enum_values][1][default]"][value="true"])
             )

      lv
      |> element(~s(button[aria-label="Use as default: staging"]))
      |> render_click()

      assert has_element?(
               lv,
               ~s(input[name="draft[inputs][0][enum_values][0][default]"][value="true"])
             )

      assert has_element?(
               lv,
               ~s(input[name="draft[inputs][0][enum_values][1][default]"][value="false"])
             )

      lv
      |> element(~s(button[aria-label="Remove default: staging"]))
      |> render_click()

      refute has_element?(lv, ~s(button[aria-pressed="true"]))

      render_click(lv, "add_enum_value", %{"index" => "0"})

      assert has_element?(
               lv,
               ~s(input[name="draft[inputs][0][enum_values][2][value]"])
             )

      assert has_element?(
               lv,
               ~s(button[aria-label="Remove allowed value"][class~="rounded-lg"][class~="ring-1"][class~="ring-zinc-800"])
             )

      enum_html = render(lv)

      assert :binary.match(enum_html, ~s(id="runbook-input-0-enum-value-0")) <
               :binary.match(enum_html, ~s(phx-click="add_enum_value"))

      lv
      |> element(~s(#runbook-input-0-enum-value-2 button[aria-label="Remove allowed value"]))
      |> render_click()

      refute has_element?(lv, ~s(input[name="draft[inputs][0][enum_values][2][value]"]))
      assert has_element?(lv, "#runbook-input-0", "Allowed values")
    end

    test "renders a type-appropriate default control and explains numeric types", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      string_html = change(lv, valid_draft(inputs: [RunbookDraft.input()]))

      assert string_html =~ "Integer — whole numbers"
      assert string_html =~ "Number — decimals allowed"

      assert string_html =~
               ~s|id="runbook-input-0-default-bounds" class="grid gap-4 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)]"|

      assert has_element?(
               lv,
               ~s(input[type="text"][name="draft[inputs][0][default]"])
             )

      assert :binary.match(string_html, ~s(name="draft[inputs][0][default]")) <
               :binary.match(string_html, ~s(name="draft[inputs][0][min_length]"))

      assert :binary.match(string_html, ~s(name="draft[inputs][0][min_length]")) <
               :binary.match(string_html, ~s(name="draft[inputs][0][max_length]"))

      boolean =
        RunbookDraft.input()
        |> Map.merge(%{"type" => "boolean", "default" => "false"})

      change(lv, valid_draft(inputs: [boolean]), ["draft", "inputs", "0", "type"])

      assert has_element?(
               lv,
               ~s(select[name="draft[inputs][0][default]"] option[value="false"][selected])
             )

      refute has_element?(lv, ~s([name="draft[inputs][0][minimum]"]))
      refute has_element?(lv, ~s([name="draft[inputs][0][maximum]"]))
      refute has_element?(lv, ~s([name="draft[inputs][0][min_length]"]))
      refute has_element?(lv, ~s([name="draft[inputs][0][max_length]"]))

      integer =
        RunbookDraft.input()
        |> Map.merge(%{"type" => "integer", "minimum" => "1", "maximum" => "10"})

      integer_html =
        change(lv, valid_draft(inputs: [integer]), ["draft", "inputs", "0", "type"])

      assert integer_html =~ "Minimum value"
      assert integer_html =~ "Maximum value"

      assert has_element?(
               lv,
               ~s(input[type="number"][step="1"][name="draft[inputs][0][default]"])
             )

      assert has_element?(
               lv,
               ~s(#runbook-input-0-default-bounds input[name="draft[inputs][0][minimum]"])
             )

      assert has_element?(
               lv,
               ~s(#runbook-input-0-default-bounds input[name="draft[inputs][0][maximum]"])
             )

      assert :binary.match(integer_html, ~s(name="draft[inputs][0][default]")) <
               :binary.match(integer_html, ~s(name="draft[inputs][0][minimum]"))

      assert :binary.match(integer_html, ~s(name="draft[inputs][0][minimum]")) <
               :binary.match(integer_html, ~s(name="draft[inputs][0][maximum]"))

      number = RunbookDraft.input() |> Map.put("type", "number")
      change(lv, valid_draft(inputs: [number]), ["draft", "inputs", "0", "type"])

      assert has_element?(
               lv,
               ~s(input[type="number"][step="any"][name="draft[inputs][0][default]"])
             )
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

      collection_html = render(lv)

      assert :binary.match(
               collection_html,
               ~s(id="runbook-stage-0-step-0-output-0")
             ) < :binary.match(collection_html, ~s(phx-click="add_output"))

      assert :binary.match(
               collection_html,
               ~s(id="runbook-stage-0-step-0-condition-0")
             ) < :binary.match(collection_html, ~s(phx-click="add_success"))

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-output-0-identity[class~="sm:grid-cols-[minmax(0,1fr)_9rem]"][class~="sm:items-end"]|
             )

      sensitive_name = "draft[stages][0][steps][0][outputs][0][sensitive]"

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-output-0-identity label",
               "Sensitive"
             )

      assert has_element?(
               lv,
               ~s|input[type="hidden"][name="#{sensitive_name}"][value="false"]|
             )

      assert has_element?(
               lv,
               ~s|input[type="checkbox"][name="#{sensitive_name}"][value="true"]:not([checked])|
             )

      refute has_element?(lv, ~s|select[name="#{sensitive_name}"]|)
      refute has_element?(lv, "#runbook-stage-0-step-0-output-0-identity", "Visibility")

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-output-0-extractor[class~="lg:grid-cols-[12rem_12rem_minmax(0,1fr)]"]|
             )

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-condition-0-controls[class~="lg:grid-cols-[minmax(0,1fr)_13rem_minmax(0,1.5fr)]"]|
             )

      assert :binary.match(collection_html, ~s(name="draft[stages][0][steps][0][outputs][0][id]")) <
               :binary.match(
                 collection_html,
                 ~s(name="draft[stages][0][steps][0][outputs][0][sensitive]")
               )

      assert :binary.match(
               collection_html,
               ~s(name="draft[stages][0][steps][0][outputs][0][source]")
             ) <
               :binary.match(
                 collection_html,
                 ~s(name="draft[stages][0][steps][0][outputs][0][extract_type]")
               )

      assert :binary.match(
               collection_html,
               ~s(name="draft[stages][0][steps][0][outputs][0][extract_type]")
             ) <
               :binary.match(
                 collection_html,
                 ~s(name="draft[stages][0][steps][0][outputs][0][expression]")
               )

      assert :binary.match(
               collection_html,
               ~s(name="draft[stages][0][steps][0][success][0][output]")
             ) <
               :binary.match(
                 collection_html,
                 ~s(name="draft[stages][0][steps][0][success][0][operator]")
               )

      assert :binary.match(
               collection_html,
               ~s(name="draft[stages][0][steps][0][success][0][operator]")
             ) <
               :binary.match(
                 collection_html,
                 ~s(name="draft[stages][0][steps][0][success][0][value]")
               )

      sensitive_output = RunbookDraft.output() |> Map.put("sensitive", "true")

      sensitive_draft =
        valid_draft()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
          [sensitive_output]
        )

      change(lv, sensitive_draft)

      assert has_element?(
               lv,
               ~s|input[type="checkbox"][name="#{sensitive_name}"][value="true"][checked][class~="text-zinc-500"]|
             )

      assert get_in(
               canonical_definition(sensitive_draft),
               [
                 "stages",
                 Access.at(0),
                 "steps",
                 Access.at(0),
                 "outputs",
                 Access.at(0),
                 "sensitive"
               ]
             )
    end

    test "retry controls share one stable desktop row", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft =
        valid_draft()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "wait", "enabled"],
          "true"
        )

      change(lv, draft)
      render_click(lv, "toggle_panel", %{"key" => "wait-0-0"})
      html = render(lv)

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-wait-controls[class~="lg:grid-cols-[minmax(16rem,2fr)_minmax(9rem,1fr)_minmax(9rem,1fr)_minmax(11rem,1fr)]"]|
             )

      assert :binary.match(html, ~s(name="draft[stages][0][steps][0][wait][enabled]")) <
               :binary.match(
                 html,
                 ~s(name="draft[stages][0][steps][0][wait][interval_seconds]")
               )

      assert :binary.match(
               html,
               ~s(name="draft[stages][0][steps][0][wait][interval_seconds]")
             ) <
               :binary.match(
                 html,
                 ~s(name="draft[stages][0][steps][0][wait][timeout_seconds]")
               )

      assert :binary.match(
               html,
               ~s(name="draft[stages][0][steps][0][wait][timeout_seconds]")
             ) <
               :binary.match(
                 html,
                 ~s(name="draft[stages][0][steps][0][wait][max_attempts]")
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
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][action_choice]"][value=""])
             )

      assert has_element?(
               lv,
               ~s(button[data-combobox-option][data-value="linux-core|linux.uptime"]),
               "linux.uptime"
             )
    end

    test "choosing an action preserves targets selected through the target picker", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      add_target =
        ~s(#runbook-stage-0-step-0-target-options button[phx-click="add_target"][phx-value-target="group:default"][phx-value-selection="all"])

      lv |> element(add_target) |> render_click()

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · all"
             )

      lv
      |> form("#runbook-editor-form")
      |> render_change(%{
        "_target" => ["draft", "stages", "0", "steps", "0", "action_choice"],
        "draft" => %{
          "stages" => %{
            "0" => %{
              "steps" => %{"0" => %{"action_choice" => "linux-core|linux.uptime"}}
            }
          }
        }
      })

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · all"
             )

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][action_choice]"][value="linux-core|linux.uptime"])
             )
    end

    test "a group can target one online runner without exposing another definition shape", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options [data-target-group="default"]),
               "1 online"
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_all"]),
               "Every runner in group"
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_all"] [data-target-scope-icon="group_all"][data-accent-dots="4"][data-neutral-dots="0"])
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_one"]),
               "One random runner"
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_one"] [data-target-scope-icon="group_one"][data-accent-dots="1"][data-neutral-dots="3"])
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="runner"]),
               runner.name
             )

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="runner"] [data-target-scope-icon="runner"][data-accent-dots="1"][data-neutral-dots="0"])
             )

      refute render(lv) =~ "Every online runner"
      refute render(lv) =~ "Frozen at run start"
      refute render(lv) =~ "Exact runner"

      assert {:ok, runner_ref} = Emisar.Runners.public_ref(runner)

      exact_target =
        ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="runner"][phx-value-target="runner:#{runner_ref}"])

      lv |> element(exact_target) |> render_click()

      assert has_element?(lv, "#runbook-stage-0-step-0-target-trigger", runner.name)

      assert has_element?(
               lv,
               ~s(#{exact_target}[phx-click="remove_target"]),
               runner.name
             )

      lv |> element(~s(#{exact_target}[phx-click="remove_target"])) |> render_click()

      lv
      |> element(
        ~s(#runbook-stage-0-step-0-target-options button[phx-click="add_target"][phx-value-target="group:default"][phx-value-selection="random_one"])
      )
      |> render_click()

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · one"
             )

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][target_selection]"][value="random_one"])
             )

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][target_refs][]"][value="group:default"])
             )

      lv
      |> form("#runbook-editor-form")
      |> render_change(%{
        "_target" => ["draft", "stages", "0", "steps", "0", "action_choice"],
        "draft" => %{
          "stages" => %{
            "0" => %{
              "steps" => %{"0" => %{"action_choice" => "linux-core|linux.uptime"}}
            }
          }
        }
      })

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · one"
             )

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][target_selection]"][value="random_one"])
             )
    end

    test "the target trigger names selections and bounds overflow", %{
      conn: conn,
      user: user,
      account: account
    } do
      first = arrange_current_action(account, user)
      second = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-two")
      third = Fixtures.Runners.create_runner(account_id: account.id, name: "runner-three")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      for runner <- [first, second] do
        assert {:ok, ref} = Emisar.Runners.public_ref(runner)

        lv
        |> element(
          ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="runner"][phx-value-target="runner:#{ref}"])
        )
        |> render_click()
      end

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "#{first.name}, runner-two"
             )

      assert {:ok, third_ref} = Emisar.Runners.public_ref(third)

      lv
      |> element(
        ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="runner"][phx-value-target="runner:#{third_ref}"])
      )
      |> render_click()

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "#{first.name}, runner-two +1"
             )
    end

    test "a large target catalog is searchable without inflating option rows", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)

      for index <- 1..6 do
        Fixtures.Runners.create_runner(
          account_id: account.id,
          name: "fleet-runner-#{index}"
        )
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-options[phx-hook=FilterableList] input[data-filterable-search][aria-label='Search targets']"
             )

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-options [data-filterable-section][data-filter-search=default]"
             )

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-options button[data-filterable-item][class*='min-h-10']"
             )

      refute has_element?(
               lv,
               "#runbook-stage-0-step-0-target-options button[data-filterable-item][class*='min-h-14']"
             )
    end

    test "a resolved target keeps a genuinely unavailable action actionable", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft =
        valid_draft()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "action"],
          "linux.missing"
        )

      html = change(lv, draft)

      assert html =~ "Unavailable · linux.missing"

      refute has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-overview button[data-combobox-trigger][disabled])
             )

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-action-error-tt[tabindex=\"0\"][aria-describedby=\"runbook-stage-0-step-0-action-error\"]"
             )

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-action-error[role=\"tooltip\"]",
               "This action is not available on every selected runner. Choose another action or update the targets."
             )

      refute has_element?(lv, "#runbook-stage-0-step-0-overview > p")
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

      assert html =~ "Required file path"
      assert html =~ "Optional whole number"
      assert html =~ "Required text value"
      refute has_element?(lv, "datalist#runbook-actions")

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][action_choice]"])
             )

      remove_target =
        ~s(#runbook-stage-0-step-0-target-options button[phx-click="remove_target"][phx-value-target="group:default"][phx-value-selection="all"])

      lv |> element(remove_target) |> render_click()

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "Choose runners or groups…"
             )

      add_target =
        ~s(#runbook-stage-0-step-0-target-options button[phx-click="add_target"][phx-value-target="group:default"][phx-value-selection="all"])

      lv |> element(add_target) |> render_click()

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-target-trigger",
               "DEFAULT · all"
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
      assert runbook.definition == canonical_definition(draft)

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

      assert has_element?(
               lv,
               ~s(#runbook-actions-desktop-publish-reason-tt[tabindex="0"][aria-describedby="runbook-actions-desktop-publish-reason"])
             )

      assert has_element?(
               lv,
               "#runbook-actions-desktop-publish-reason[role=\"tooltip\"]",
               "Wait for the publish check to finish."
             )

      send(lv.pid, {:runbook_preview, 1})
      html = render(lv)

      assert html =~ "Ready to publish", html |> LazyHTML.from_fragment() |> LazyHTML.text()
      assert html =~ "Resolved"
      refute html =~ "Checked"
      assert html =~ "1"

      assert has_element?(
               lv,
               "#runbook-actions-desktop-publish:not([disabled])",
               "Publish"
             )

      refute has_element?(lv, "#runbook-actions-desktop-publish-reason")

      destination = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^destination}}} =
               render_click(lv, "publish", %{})

      assert Repo.one!(Runbook).status == :published
    end

    test "a stale ready preview cannot publish once current state breaks", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      change(lv, valid_draft())
      send(lv.pid, {:runbook_preview, 1})
      assert render(lv) =~ "Ready to publish"

      # The catalog the preview judged is gone by the time the operator clicks.
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      html = render_click(lv, "publish", %{})
      assert html =~ "Current preflight must pass before publishing."
      refute html =~ "Ready to publish"
      refute Repo.exists?(Runbook)
    end

    test "save-and-publish of an edited runbook commits nothing when readiness fails", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = arrange_current_action(account, user)
      subject = owner_subject(user, account)

      {:ok, draft} =
        Runbooks.create_runbook(
          %{
            "title" => "Fleet health",
            "slug" => "fleet-health",
            "definition" => canonical_definition(valid_draft())
          },
          subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{draft.id}/edit")

      change(lv, valid_draft(title: "Fleet health v2"))
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      html = render_click(lv, "publish", %{})
      assert html =~ "Current preflight must pass before publishing."

      # One committed row: the original draft — no orphaned v2 from the
      # failed save-and-publish.
      assert [%Runbook{version: 1, status: :draft}] = Repo.all(Runbook)
    end

    test "saves incomplete work as a draft while strict validation blocks publication", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/new")
      assert html =~ "Build the first stage"
      assert has_element?(lv, "button[disabled]", "Save draft")

      assert has_element?(
               lv,
               "#runbook-actions-desktop-save-reason[role=\"tooltip\"]",
               "No unsaved changes."
             )

      assert has_element?(
               lv,
               "#runbook-actions-mobile-save-reason[role=\"tooltip\"]",
               "No unsaved changes."
             )

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
      assert has_element?(lv, "#runbook-actions-desktop-save:not([disabled])", "Save draft")
      refute has_element?(lv, "#runbook-actions-desktop-save-reason")
      assert has_element?(lv, "button[disabled]", "Publish")

      assert has_element?(
               lv,
               "#runbook-actions-desktop-publish-reason[role=\"tooltip\"]",
               "Fix the 1 definition issue before publishing."
             )

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{status: :draft} = Repo.one!(Runbook)
    end

    test "a crafted composite scalar becomes draft text instead of crashing the editor", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      input =
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "count",
          "description" => "Number of observations",
          "type" => "integer",
          "default" => %{"nested" => "1"}
        })

      html = change(lv, valid_draft(inputs: [input]))

      assert html =~ "Input 1 · Default"
      assert html =~ "Default does not satisfy the input&#39;s type and constraints."

      # The same normalizer owns every scalar position, not only input defaults.
      wait = %{
        "enabled" => "true",
        "interval_seconds" => %{"nested" => "1"},
        "timeout_seconds" => "120",
        "max_attempts" => "12"
      }

      draft =
        [inputs: [input]]
        |> valid_draft()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "wait"], wait)

      change(lv, draft)
      render_click(lv, "toggle_panel", %{"key" => "wait-0-0"})

      assert has_element?(
               lv,
               ~s|input[name="draft[stages][0][steps][0][wait][interval_seconds]"][value='{"nested":"1"}']|
             )

      params = valid_draft() |> form_params() |> put_in(["inputs", "0"], "not-a-row")

      html =
        render_change(lv, "draft_changed", %{
          "_target" => ["draft", "inputs", "0"],
          "draft" => params
        })

      assert html =~ "Input 1"
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

      assert has_element?(
               lv,
               "#runbook-actions-desktop-publish-reason[role=\"tooltip\"]",
               "Fix the errors in Details before publishing."
             )

      assert has_element?(
               lv,
               "#runbook-actions-desktop-save-reason[role=\"tooltip\"]",
               "Fix the errors in Details before saving."
             )
    end

    test "a viewer inspects the same structured definition without mutation controls", %{
      user: owner,
      account: account
    } do
      subject = owner_subject(owner, account)

      input =
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "scope",
          "description" => "Incident scope",
          "type" => "enum",
          "enum_values" => [%{"value" => "database"}]
        })

      {:ok, runbook} =
        Runbooks.create_runbook(
          %{
            "title" => "Fleet health",
            "slug" => "fleet-health",
            "definition" => canonical_definition(valid_draft(inputs: [input]))
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
      assert has_element?(lv, "#runbook-lifecycle-desktop", "Current")
      assert has_element?(lv, "#runbook-lifecycle-desktop", "v1")
      assert has_element?(lv, "#runbook-lifecycle-desktop", "draft")

      assert :binary.match(html, ~s(id="runbook-lifecycle-desktop")) <
               :binary.match(html, ~s(name="draft[title]"))

      assert has_element?(lv, "#runbook-editor-form input[disabled]")
      refute has_element?(lv, "button", "Save draft")
      refute has_element?(lv, "#delete-runbook")
      refute has_element?(lv, "button", "Add input")
      refute has_element?(lv, ~s(button[aria-label="Remove input"]))
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

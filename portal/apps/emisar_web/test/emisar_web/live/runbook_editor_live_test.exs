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
    version = Keyword.get(opts, :version, "1.4.3")
    hash = Fixtures.Catalog.pack_hash("linux-core-#{version}")

    assert {:ok, runner} =
             Catalog.observe_state(runner, %{
               "hostname" => runner.hostname,
               "version" => runner.runner_version,
               "labels" => runner.labels,
               "enforce_signatures" => false,
               "packs" => %{"linux-core" => %{"version" => version, "hash" => hash}},
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
               "default · all · 1 unavailable"
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

      # A closed panel still carries every authored value, so the next change
      # anywhere in the form cannot reset the wait policy to its default.
      assert has_element?(lv, ~s|#runbook-stage-0-step-0-wait-controls[class~="hidden"]|)

      assert has_element?(
               lv,
               ~s|input[name="draft[stages][0][steps][0][wait][interval_seconds]"][value="10"]|
             )

      render_click(lv, "toggle_panel", %{"key" => "wait-0-0"})
      html = render(lv)

      refute has_element?(lv, ~s|#runbook-stage-0-step-0-wait-controls[class~="hidden"]|)

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-wait-controls[class~="lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,1.3fr)]"]|
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
               "default · all"
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
               "default · all"
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
               "default · one"
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
               "default · one"
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

    test "a stale saved action stays named without lending risk or arguments", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user,
        args: [%{"name" => "path", "type" => "path", "required" => true, "sensitive" => false}]
      )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft =
        valid_draft()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "action"], "linux.retired")

      html = change(lv, draft)

      assert html =~ "Unavailable · linux.retired"
      refute html =~ "Low — read-only or trivially reversible"

      refute has_element?(
               lv,
               ~s(input[type=hidden][name="draft[stages][0][steps][0][args][0][name]"])
             )
    end

    test "selected runners with incompatible contracts make the action unavailable", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      arrange_current_action(account, user, version: "2.0.0", risk: "critical")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      html = change(lv, valid_draft())

      assert html =~ "Unavailable · linux.uptime"
      refute html =~ "Low — read-only or trivially reversible"
      refute html =~ "Critical — data loss or irreversible"

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-action-error[role=\"tooltip\"]",
               "This action is not available on every selected runner. Choose another action or update the targets."
             )

      # The saved choice stays named and selectable-looking nowhere: it is the
      # one disabled option, so the operator can still see what was authored.
      assert has_element?(
               lv,
               ~s(button[data-combobox-option][data-value="linux-core|linux.uptime"][disabled]),
               "linux.uptime"
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
               "default · all"
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

    test "every fact phrase completes the sentence its name starts", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      outputs = [
        %{RunbookDraft.output() | "id" => "healthy", "expression" => "/healthy"},
        %{
          RunbookDraft.output()
          | "id" => "has_error",
            "source" => "stdout",
            "extract_type" => "contains",
            "expression" => "error"
        },
        %{
          RunbookDraft.output()
          | "id" => "panics",
            "source" => "stderr",
            "extract_type" => "grep",
            "expression" => "panic"
        },
        %{
          RunbookDraft.output()
          | "id" => "version",
            "source" => "stdout",
            "extract_type" => "regex",
            "expression" => "v(\\d+)",
            "capture" => "1"
        },
        %{
          RunbookDraft.output()
          | "id" => "token",
            "source" => "stdout",
            "extract_type" => "regex",
            "expression" => "tok-.+",
            "sensitive" => "true"
        }
      ]

      conditions = [
        %{
          RunbookDraft.success()
          | "output" => "healthy",
            "operator" => "greater_than_or_equal",
            "value" => "2"
        },
        %{
          RunbookDraft.success()
          | "output" => "version",
            "operator" => "one_of",
            "value" => ~s(["a"])
        }
      ]

      argument = %{
        RunbookDraft.argument()
        | "name" => "path",
          "type" => "path",
          "required" => "true",
          "sensitive" => "false",
          "source" => "literal",
          "value" => "/etc/caddy/Caddyfile"
      }

      step = %{
        RunbookDraft.step()
        | "collapsed" => "true",
          "id" => "check",
          "pack_id" => "linux-core",
          "action" => "linux.uptime",
          "args" => [argument],
          "outputs" => outputs,
          "success" => conditions
      }

      change(lv, put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0)], step))

      details = "#runbook-stage-0-step-0-details"

      assert has_element?(lv, details, "set to")
      assert has_element?(lv, details, "from structured output at")
      assert has_element?(lv, details, "whether stdout contains")
      assert has_element?(lv, details, "lines in stderr containing")
      assert has_element?(lv, details, "capture 1 of")
      assert has_element?(lv, details, "what")
      assert has_element?(lv, details, "matches in stdout")
      assert has_element?(lv, details, "(sensitive)")
      assert has_element?(lv, details, "is greater than or equal to")
      assert has_element?(lv, details, "is one of")

      # The extractor kind is never dropped in as a bare noun.
      refute has_element?(lv, details, "JSON Pointer")
    end

    test "a stage and an open step lead with the identifier they were given", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      assert has_element?(lv, "#runbook-stage-0 h3", "stage")
      assert has_element?(lv, "#runbook-stage-0", "Stage 1 · sequential")
      assert has_element?(lv, "#runbook-stage-0-step-0", "step")
      assert has_element?(lv, "#runbook-stage-0-step-0", "Step 1")

      change(lv, valid_draft())

      assert has_element?(lv, "#runbook-stage-0 h3", "inspect")
      assert has_element?(lv, "#runbook-stage-0", "Stage 1 · parallel · up to 4 at once")

      # A row with no identifier yet has only its position to go by.
      unnamed =
        valid_draft()
        |> put_in(["stages", Access.at(0), "id"], "")
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "id"], "")

      change(lv, unnamed)

      assert has_element?(lv, "#runbook-stage-0 h3", "Stage 1")
      refute has_element?(lv, "#runbook-stage-0 h3", "inspect")
    end

    test "an authored step opens as a summary that one click turns back into its form", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user,
        args: [%{"name" => "path", "type" => "path", "required" => true, "sensitive" => false}]
      )

      subject = owner_subject(user, account)

      input =
        RunbookDraft.input()
        |> Map.merge(%{"id" => "config_path", "description" => "Config file"})

      argument =
        RunbookDraft.argument()
        |> Map.merge(%{
          "name" => "path",
          "type" => "path",
          "required" => "true",
          "source" => "input",
          "ref" => "config_path"
        })

      output = Map.merge(RunbookDraft.output(), %{"id" => "healthy", "expression" => "/healthy"})
      condition = Map.merge(RunbookDraft.success(), %{"output" => "healthy", "value" => "true"})
      step = ["stages", Access.at(0), "steps", Access.at(0)]

      draft =
        valid_draft(inputs: [input])
        |> put_in(step ++ ["args"], [argument])
        |> put_in(step ++ ["outputs"], [output])
        |> put_in(step ++ ["success"], [condition])
        |> put_in(step ++ ["wait", "enabled"], "true")

      {:ok, runbook} =
        Runbooks.create_runbook(
          %{
            "title" => "Fleet health",
            "slug" => "fleet-health",
            "definition" => canonical_definition(draft)
          },
          subject
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      summary = "#runbook-stage-0-step-0-summary"
      details = "#runbook-stage-0-step-0-details"

      # The run surface's plan-row grammar: the shared ordered list carrying the
      # stage's own marker, an action · target head, then the fact groups.
      assert has_element?(lv, ~s|#runbook-stage-0 ol [data-steps-marker="parallel"]|)
      assert has_element?(lv, summary, "linux.uptime")

      # How far the ref reaches is spelled out, not encoded in scope dots that
      # need a tooltip to say the same thing.
      assert has_element?(lv, summary, "Every runner in default")
      refute has_element?(lv, ~s|#{summary} [data-target-scope-icon]|)

      # The phrase says what it is, so no glyph labels it.
      refute has_element?(lv, summary, "→")
      assert has_element?(lv, summary, "uptime")
      assert has_element?(lv, details, "from run-time input")
      assert has_element?(lv, details, "from structured output at")

      # An operator-supplied value reads like the name it belongs to.
      assert has_element?(lv, "#{details} span[class*='font-mono']", "config_path")
      assert has_element?(lv, "#{details} span[class*='font-mono']", "/healthy")
      assert has_element?(lv, "#{details} span[class*='font-mono']", "true")

      assert has_element?(
               lv,
               details,
               "observe again every 10s, for up to 12 observations or 120s"
             )

      # Every value sits beside its own name, in one column per step.
      assert has_element?(lv, ~s|#{details} dl[class*="max-content"]|)
      assert has_element?(lv, "#{details} dt", "Arguments")
      assert has_element?(lv, ~s|#runbook-stage-0-step-0-form[class~="hidden"]|)

      assert has_element?(
               lv,
               ~s|input[type="hidden"][name="draft[stages][0][steps][0][collapsed]"][value="true"]|
             )

      assert has_element?(
               lv,
               ~s|button[phx-click="toggle_step"][phx-value-step="0"][aria-expanded="false"]|,
               "Edit"
             )

      # Collapsed, the step is a list row: the list's own divider separates it,
      # it keeps the rail marker, and it carries no enclosure of its own.
      refute has_element?(lv, ~s|li[class*="border-dashed"] #runbook-stage-0-step-0|)
      assert has_element?(lv, "#runbook-stage-0 li [data-steps-marker]")

      render_click(lv, "toggle_step", %{"stage" => "0", "step" => "0"})

      # Expanded, it is a form several screens tall, so the ROW takes the dashed
      # enclosure that says where it ends and the next step begins — and drops
      # the rail, which would only indent the fields inside the panel.
      assert has_element?(lv, ~s|li[class*="border-dashed"] #runbook-stage-0-step-0|)
      refute has_element?(lv, ~s|li[class*="border-dashed"] [data-steps-marker]|)

      refute has_element?(lv, summary)
      refute has_element?(lv, details)
      refute has_element?(lv, ~s|#runbook-stage-0-step-0-form[class~="hidden"]|)
      assert has_element?(lv, "#runbook-stage-0-step-0-form button", "Add output")
      assert has_element?(lv, ~s|button[phx-click="toggle_step"]|, "Collapse")

      # Expanded, the head keeps only the position the fields below cannot show.
      assert has_element?(lv, "#runbook-stage-0-step-0", "Step 1")

      # Disclosure alone leaves the draft clean — no new version to save.
      assert has_element?(lv, "#runbook-actions-desktop-save-reason", "No unsaved changes.")
    end

    test "a step added in this session opens as a form and keeps its own disclosure", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      refute has_element?(lv, "#runbook-stage-0-step-0-summary")
      refute has_element?(lv, ~s|#runbook-stage-0-step-0-form[class~="hidden"]|)

      render_click(lv, "add_step", %{"stage" => "0"})
      render_click(lv, "toggle_step", %{"stage" => "0", "step" => "0"})

      assert has_element?(lv, ~s|#runbook-stage-0-step-0-form[class~="hidden"]|)
      refute has_element?(lv, ~s|#runbook-stage-0-step-1-form[class~="hidden"]|)

      # A later change anywhere in the form posts the collapsed step too, so the
      # browser's hidden field is what keeps it collapsed.
      collapsed_step = %{
        RunbookDraft.step()
        | "collapsed" => "true",
          "id" => "uptime",
          "pack_id" => "linux-core",
          "action" => "linux.uptime"
      }

      change(
        lv,
        put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0)], collapsed_step)
      )

      assert has_element?(lv, "#runbook-stage-0-step-0-summary", "linux.uptime")
      assert has_element?(lv, ~s|#runbook-stage-0-step-0-form[class~="hidden"]|)
    end

    test "a collapsed step reports how many definition issues it still carries", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      unnamed_step = %{
        RunbookDraft.step()
        | "collapsed" => "true",
          "id" => "",
          "pack_id" => "linux-core",
          "action" => "linux.uptime",
          "target_refs" => ["group:default"]
      }

      change(
        lv,
        put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0)], unnamed_step)
      )

      assert has_element?(lv, "#runbook-stage-0-step-0", "1 issue")

      render_click(lv, "toggle_step", %{"stage" => "0", "step" => "0"})

      refute has_element?(lv, "#runbook-stage-0-step-0", "1 issue")
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

      # Disclosure is inspection, so it stays available and says so.
      assert has_element?(lv, ~s|button[phx-click="toggle_step"]|, "Show")
      render_click(lv, "toggle_step", %{"stage" => "0", "step" => "0"})
      assert has_element?(lv, ~s|button[phx-click="toggle_step"]|, "Hide")
    end

    test "the lifecycle rail names the version that runs under an unpublished draft", %{
      conn: conn,
      user: owner,
      account: account
    } do
      subject = owner_subject(owner, account)

      {:ok, drafted} =
        Runbooks.create_runbook(
          %{
            "title" => "Fleet health",
            "slug" => "fleet-health",
            "definition" => canonical_definition(valid_draft())
          },
          subject
        )

      published = Fixtures.Runbooks.publish_runbook(drafted)
      {:ok, pending} = Runbooks.save_new_version(published, %{}, subject)

      {:ok, editing_draft, _html} =
        live(conn, ~p"/app/#{account}/runbooks/#{pending.id}/edit")

      assert has_element?(editing_draft, "#runbook-lifecycle-desktop", "Current")
      assert has_element?(editing_draft, "#runbook-lifecycle-desktop", "v2")
      assert has_element?(editing_draft, "#runbook-lifecycle-desktop", "Runs today")
      assert has_element?(editing_draft, "#runbook-lifecycle-desktop", "v1")

      # The published head IS what runs, so naming it again would render the
      # same fact twice.
      {:ok, editing_published, _html} =
        live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      refute has_element?(editing_published, "#runbook-lifecycle-desktop", "Runs today")
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

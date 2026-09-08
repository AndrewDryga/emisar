defmodule EmisarWeb.RunbookEditorLiveTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Catalog, Fixtures, Repo, Runbooks}
  alias Emisar.Runbooks.{Release, Runbook}
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
                   "output_schema" => Keyword.get(opts, :output_schema),
                   "examples" => [],
                   "search_terms" => []
                 }
               ]
             })

    subject = owner_subject(user, account)
    versions = Fixtures.Catalog.list_pack_versions(subject.account.id)

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

      assert html =~ "Instructions"
      assert html =~ "Inputs"
      assert has_element?(lv, "#runbook-stages", "Stages run in order")
      assert html =~ "Arguments"
      assert html =~ "Extracted outputs"
      refute html =~ "No extracted outputs."
      refute html =~ "No inputs."
      assert has_element?(lv, "#runbook-inputs button", "Add input")
      assert has_element?(lv, "#runbook-stage-0-step-0-outputs button", "Add output")
      assert html =~ "Success conditions"
      assert has_element?(lv, "#runbook-stage-0-step-0-wait", "When conditions aren't met")
      assert html =~ "Build the first stage"
      refute html =~ "Choose runners first"
      refute html =~ "Only online, enabled runners with the required trusted action are included."
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
      assert has_element?(lv, ~s(input[name="draft[stages][1][id]"][value=""]))

      assert has_element?(
               lv,
               ~s(input[name="draft[stages][1][steps][0][id]"][value=""])
             )

      assert has_element?(lv, "#runbook-stages button", "Add stage")

      staged_html = render(lv)
      add_stage_position = staged_html |> :binary.matches("Add stage") |> List.last()

      assert :binary.match(staged_html, ~s(id="runbook-stage-1")) < add_stage_position

      render_click(lv, "add_step", %{"stage" => "0"})
      assert has_element?(lv, "#runbook-stage-0-step-1")

      assert has_element?(
               lv,
               ~s(input[name="draft[stages][0][steps][1][id]"][value=""])
             )

      html = change(lv, valid_draft())
      assert has_element?(lv, ~s(input[name="draft[stages][0][max_parallel]"]))
      assert has_element?(lv, "#runbook-stage-0-overview label", "Max parallel actions")
      refute has_element?(lv, "#runbook-stage-0-overview", "Maximum simultaneous actions")
      assert html =~ "xl:grid-cols-[9rem_minmax(0,1fr)_10rem_11rem]"

      assert has_element?(
               lv,
               "#runbook-inputs",
               "Mark sensitive inputs to hide their values in plans, approvals, and results."
             )

      # An answer-shaped fragment ("Yes - …") is leaked review dialogue, not
      # copy — this pinned the defect once, so pin its absence now.
      refute html =~ "Yes - masked"

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
               "#runbook-stage-0-step-0-target-options",
               "This group is outside your action access or has no available runners"
             )

      refute html =~ "All available runners in default (unavailable)"

      assert has_element?(
               lv,
               ~s(#runbook-stage-0-step-0-target-options button[data-target-kind="group_all"][phx-click="remove_target"][phx-value-target="group:default"][phx-value-selection="all"]),
               "default group This group is outside your action access or has no available runners Unavailable"
             )

      refute has_element?(lv, "#runbook-stage-0-step-0-targets > .mt-2.space-y-2")

      assert :binary.match(html, "Instructions") <
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
               ~s(button[aria-label="Remove allowed value"][phx-click="remove_enum_value"])
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
               ~s|#runbook-stage-0-step-0-output-0-extractor[class~="@2xl:grid-cols-[12rem_12rem_minmax(0,1fr)]"]|
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

      regex_output =
        RunbookDraft.output()
        |> Map.merge(%{
          "extract_type" => "regex",
          "expression" => "status=(\\w+)",
          "capture" => "1"
        })

      regex_draft =
        valid_draft()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
          [regex_output]
        )

      change(lv, regex_draft)

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-output-0-extractor[class~="@2xl:grid-cols-[12rem_12rem_minmax(0,1fr)_7rem]"]|
             )

      for field <- ["source", "extract_type", "expression", "capture"] do
        assert has_element?(
                 lv,
                 ~s|#runbook-stage-0-step-0-output-0-extractor [name="draft[stages][0][steps][0][outputs][0][#{field}]"]|
               )
      end

      assert has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-output-0-extractor input[name$="[capture]"][value="1"]|
             )

      sensitive_output = RunbookDraft.output() |> Map.put("sensitive", "true")

      sensitive_draft =
        valid_draft()
        |> put_in(
          ["stages", Access.at(0), "steps", Access.at(0), "outputs"],
          [sensitive_output]
        )

      change(lv, sensitive_draft)

      refute has_element?(
               lv,
               ~s|#runbook-stage-0-step-0-output-0-extractor input[name$="[capture]"]|
             )

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
               ~s|input[name="draft[stages][0][steps][0][wait][max_attempts]"][min="2"][max="100"][step="1"]|
             )

      refute html =~ "Includes the first attempt."

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-wait-help",
               "Choose an available low-risk action to configure repeats."
             )

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

    test "repeat help follows conditions and the current limits", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      step = ["stages", Access.at(0), "steps", Access.at(0)]
      help = "#runbook-stage-0-step-0-wait-help"

      draft = valid_draft()
      change(lv, draft)
      assert has_element?(lv, help, "This action runs once.")

      draft = put_in(draft, step ++ ["wait", "enabled"], "true")
      change(lv, draft)
      assert has_element?(lv, help, "Add a success condition to use repeats.")

      output =
        RunbookDraft.output()
        |> Map.merge(%{
          "id" => "ready",
          "source" => "stdout",
          "extract_type" => "contains",
          "expression" => "ready"
        })

      draft =
        draft
        |> put_in(step ++ ["outputs"], [output])
        |> put_in(step ++ ["success"], [
          %{"output" => "ready", "operator" => "equals", "value" => "true"}
        ])

      change(lv, draft)
      assert has_element?(lv, help, "Repeat every 10 seconds until conditions pass")
      assert has_element?(lv, help, "12 attempts or 120 seconds")
      assert has_element?(lv, help, "Action failures stop the execution.")

      draft =
        draft
        |> put_in(step ++ ["wait", "interval_seconds"], "15")
        |> put_in(step ++ ["wait", "timeout_seconds"], "60")
        |> put_in(step ++ ["wait", "max_attempts"], "4")

      change(lv, draft)
      assert has_element?(lv, help, "Repeat every 15 seconds until conditions pass")
      assert has_element?(lv, help, "4 attempts or 60 seconds")
      refute has_element?(lv, help, "12 attempts")

      change(lv, put_in(draft, step ++ ["wait", "max_attempts"], "1"))
      assert has_element?(lv, help, "Enter valid repeat limits.")
      refute has_element?(lv, help, "Repeat every")

      change(lv, put_in(draft, step ++ ["wait", "enabled"], "false"))
      assert has_element?(lv, help, "Stop execution if a condition fails.")
      refute has_element?(lv, help, "Repeat every")
    end

    test "repeat help explains why a high-risk action cannot repeat", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user, risk: "high")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      draft =
        valid_draft()
        |> put_in(["stages", Access.at(0), "steps", Access.at(0), "wait", "enabled"], "true")

      change(lv, draft)

      assert has_element?(
               lv,
               "#runbook-stage-0-step-0-wait-help",
               "This high-risk action cannot repeat. Choose Stop execution or a low-risk action."
             )

      refute has_element?(lv, "#runbook-stage-0-step-0-wait-help", "Repeat every")
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

      refute html =~ "Version requirement"

      assert has_element?(
               lv,
               ~s(input[type="hidden"][name="draft[stages][0][steps][0][action_choice]"][value=""])
             )

      # The initial editor names the target-derived pool but does not ship
      # the catalog. The browser asks for it only when this picker opens.
      html = render(lv)
      assert html =~ ~s(data-combobox-source="runbook-action-pool-)
      refute html =~ ~s(data-value="linux-core|linux.uptime")
      refute html =~ ~s(<template id="runbook-action-pool-)

      [source] = Regex.run(~r/data-combobox-source="([^"]+)"/, html, capture: :all_but_first)

      html =
        render_hook(lv, "load_action_pool", %{
          "stage" => "0",
          "step" => "0",
          "source" => "runbook-action-pool-forged"
        })

      refute html =~ ~s(<template id="runbook-action-pool-)

      html =
        render_hook(lv, "load_action_pool", %{
          "stage" => "0",
          "step" => "0",
          "source" => source
        })

      assert html =~ ~s(data-value="linux-core|linux.uptime")
      assert html =~ ~s(<template id="runbook-action-pool-)
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
               "All available runners in group"
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
      assert runbook.live_version == nil
      assert runbook.definition == nil
      assert runbook.draft_definition == canonical_definition(draft)

      assert get_in(runbook.draft_definition, [
               "stages",
               Access.at(0),
               "steps",
               Access.at(0),
               "pack"
             ]) == %{"id" => "linux-core"}

      refute Map.has_key?(runbook.draft_definition, "steps")
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
      assert html =~ "Last checked"
      refute html =~ "Checked"
      assert html =~ "1"

      assert has_element?(
               lv,
               "#runbook-actions-desktop-publish:not([disabled])",
               "Publish"
             )

      refute has_element?(lv, "#runbook-actions-desktop-publish-reason")

      # Publishing is a confirmed step: the button opens the review, and only
      # its confirm mints the release.
      html = render_click(lv, "review_publish", %{})
      assert html =~ "Publish v1 to make this workflow available to run."
      refute Repo.exists?(Runbook)

      destination = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^destination}}} =
               render_click(lv, "publish", %{})

      assert %Runbook{} = runbook = Repo.one!(Runbook)
      assert runbook.live_version == 1
      assert runbook.draft_definition == nil
      assert Repo.one!(Release).version == 1
    end

    for dimension <- [:runners, :packs] do
      test "#{dimension} access refresh preserves the dirty editor and previous check", %{
        conn: conn,
        user: user,
        account: account
      } do
        arrange_current_action(account, user)

        membership =
          Fixtures.Memberships.fetch_membership(account.id, user.id)
          |> Fixtures.Memberships.force_role("admin")

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

        output = %{
          RunbookDraft.output()
          | "id" => "observed",
            "extract_type" => "contains",
            "expression" => "uptime"
        }

        draft =
          put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0), "outputs"], [
            output
          ])

        change(lv, draft)
        generation = :sys.get_state(lv.pid).socket.assigns.preview_generation
        send(lv.pid, {:runbook_preview, generation})
        assert render(lv) =~ "Ready to publish"
        render_click(lv, "toggle_panel", %{"key" => "preserved-panel"})
        render_click(lv, "review_publish", %{})
        before = :sys.get_state(lv.pid).socket.assigns

        {:ok, narrowed} =
          case unquote(dimension) do
            :runners -> Emisar.Accounts.RunnerAccess.new(:none)
            :packs -> Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, [])
          end

        Fixtures.Memberships.force_runner_access(membership, narrowed)
        send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
        html = render(lv)
        after_change = :sys.get_state(lv.pid).socket.assigns

        for key <- [:draft, :form, :baseline, :base_sha, :dirty?, :open_panels] do
          assert Map.fetch!(after_change, key) == Map.fetch!(before, key)
        end

        refute after_change.read_only?
        assert after_change.publish_review == nil
        assert after_change.preview.plan == before.preview.plan
        assert after_change.preview.checked_at == before.preview.checked_at
        assert html =~ "Previous check"
        refute html =~ "Ready to publish"
        assert has_element?(lv, "#runbook-actions-desktop-save[disabled]")
        assert has_element?(lv, "#runbook-actions-desktop-publish[disabled]")

        send(lv.pid, {:runbook_preview, before.preview_generation})
        render(lv)

        assert :sys.get_state(lv.pid).socket.assigns.preview_generation ==
                 after_change.preview_generation

        send(lv.pid, {:runbook_preview, after_change.preview_generation})
        assert render(lv) =~ "Previous check"
        assert :sys.get_state(lv.pid).socket.assigns.preview.plan == before.preview.plan
        assert render_click(lv, "save", %{}) =~ "within your action access"
        render_click(lv, "publish", %{})
        refute Repo.exists?(Runbook)

        Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
        send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
        render(lv)
        restored = :sys.get_state(lv.pid).socket.assigns
        assert restored.authoring_error == nil
        assert restored.draft == before.draft
        assert has_element?(lv, "#runbook-actions-desktop-save:not([disabled])")
        send(lv.pid, {:runbook_preview, restored.preview_generation})
        assert render(lv) =~ "Ready to publish"
      end
    end

    test "catalog refresh replaces hydrated action pools without changing selected values", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)

      membership =
        Fixtures.Memberships.fetch_membership(account.id, user.id)
        |> Fixtures.Memberships.force_role("admin")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      change(lv, valid_draft())

      [source] =
        Regex.run(~r/data-combobox-source="([^"]+)"/, render(lv), capture: :all_but_first)

      render_hook(lv, "load_action_pool", %{"stage" => "0", "step" => "0", "source" => source})
      before = :sys.get_state(lv.pid).socket.assigns
      assert before.action_pool.id == source

      send(
        lv.pid,
        {:list_changed, :team, "membership.runner_access_changed", Ecto.UUID.generate()}
      )

      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.catalog_generation == before.catalog_generation

      {:ok, access} = Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, ["linux-core"])
      Fixtures.Memberships.force_runner_access(membership, access)
      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      html = render(lv)
      [new_source] = Regex.run(~r/data-combobox-source="([^"]+)"/, html, capture: :all_but_first)
      assert new_source != source
      assert :sys.get_state(lv.pid).socket.assigns.draft == before.draft
      assert :sys.get_state(lv.pid).socket.assigns.authoring_error == nil
      render_hook(lv, "load_action_pool", %{"stage" => "0", "step" => "0", "source" => source})
      assert :sys.get_state(lv.pid).socket.assigns.action_pool == nil

      html =
        render_hook(lv, "load_action_pool", %{
          "stage" => "0",
          "step" => "0",
          "source" => new_source
        })

      assert html =~ ~s(data-value="linux-core|linux.uptime")

      {:ok, denied} = Emisar.Accounts.RunnerAccess.new(:all, [], [], :restricted, [])
      Fixtures.Memberships.force_runner_access(membership, denied)
      send(lv.pid, {:list_changed, :team, "membership.runner_access_changed", user.id})
      render(lv)
      repaired = put_in(before.draft, ["stages", Access.at(0), "steps"], [])
      change(lv, repaired)
      assert has_element?(lv, "#runbook-actions-desktop-save:not([disabled])")
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
      render_click(lv, "review_publish", %{})

      # The catalog the preview judged is gone by the time the operator confirms.
      Fixtures.Catalog.delete_actions_for_runner(runner.id)

      html = render_click(lv, "publish", %{})
      assert html =~ "Resolve the issues above before publishing."
      refute html =~ "Ready to publish"

      # The refused publication takes its review panel with it, so the issues
      # are what the operator reads next.
      refute html =~ "First release — publishing creates v1"

      # Publishing is save-then-publish, so the work is kept — only the release
      # is refused.
      assert %Runbook{live_version: nil, definition: nil} = created = Repo.one!(Runbook)
      refute Repo.exists?(Release)

      edited = valid_draft(title: "Fleet health follow-up")
      change(lv, edited)

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{} = saved = Repo.one!(Runbook)
      assert saved.id == created.id
      assert saved.title == "Fleet health follow-up"
      assert saved.draft_definition == canonical_definition(edited)
      refute Repo.exists?(Release)
    end

    # A publish refused ON CREATE leaves a saved draft behind, so the retry has to
    # land on THAT row: a second runbook (or a slug collision) would be the
    # operator paying for an environment problem they already fixed.
    test "retrying a refused publish-on-create mints the release on the same runbook", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = arrange_current_action(account, user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      change(lv, valid_draft())
      send(lv.pid, {:runbook_preview, 1})
      render_click(lv, "review_publish", %{})

      Fixtures.Catalog.delete_actions_for_runner(runner.id)
      html = render_click(lv, "publish", %{})
      assert html =~ "Resolve the issues above before publishing."

      assert %Runbook{live_version: nil} = created = Repo.one!(Runbook)
      # The operator's work is still on the page, not just in the row.
      assert html =~ created.title

      # The environment recovers; the operator publishes again without re-typing.
      arrange_current_action(account, user)
      send(lv.pid, {:runbook_preview, 1})
      render_click(lv, "review_publish", %{})

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "publish", %{})

      assert %Runbook{} = published = Repo.one!(Runbook)
      assert published.id == created.id
      assert published.live_version == 1
      assert Repo.one!(Release).version == 1
    end

    test "save-and-publish of an edited runbook commits nothing when readiness fails", %{
      conn: conn,
      user: user,
      account: account
    } do
      runner = arrange_current_action(account, user)

      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      change(lv, valid_draft(title: "Fleet health v2"))
      Fixtures.Catalog.delete_actions_for_runner(runner.id)
      render_click(lv, "review_publish", %{})

      html = render_click(lv, "publish", %{})
      assert html =~ "Resolve the issues above before publishing."

      # The save that preceded the refused publish stands; nothing went live.
      assert %Runbook{} = saved = Repo.one!(Runbook)
      assert saved.title == "Fleet health v2"
      assert saved.live_version == nil
      assert saved.definition == nil
      refute Repo.exists?(Release)

      edited_again = valid_draft(title: "Fleet health v3")
      change(lv, edited_again)

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{} = saved_again = Repo.one!(Runbook)
      assert saved_again.id == saved.id
      assert saved_again.title == "Fleet health v3"
      assert saved_again.draft_definition == canonical_definition(edited_again)
      refute Repo.exists?(Release)
    end

    test "an edit to a live runbook saves as its unpublished change", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)

      published =
        [
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        ]
        |> Fixtures.Runbooks.create_runbook()
        |> Fixtures.Runbooks.publish_runbook()

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      assert has_element?(lv, "#runbook-lifecycle-desktop", "Published version")
      assert has_element?(lv, "#runbook-lifecycle-desktop", "v1")
      # Clean live runbook: no divergence, so no Next row.
      refute has_element?(lv, "#runbook-lifecycle-desktop", "Next")
      assert html =~ "Discard changes"
      assert has_element?(lv, ~s(button[aria-label="Discard changes"][disabled]))

      html = render_click(lv, "discard_draft", %{})
      refute html =~ "Could not discard these changes."
      assert Repo.one!(Runbook).draft_definition == nil

      edited = valid_draft(title: "Fleet health", inputs: [RunbookDraft.input()])
      change(lv, edited)

      assert has_element?(
               lv,
               ~s|button[aria-label="Discard changes"][class~="text-amber-200"]:not([disabled])|
             )

      html = render_click(lv, "discard_draft", %{})
      assert html =~ "Unpublished changes discarded."
      assert has_element?(lv, ~s(button[aria-label="Discard changes"][disabled]))
      refute has_element?(lv, "#runbook-input-0")
      assert Repo.one!(Runbook).draft_definition == nil

      change(lv, edited)

      destination = ~p"/app/#{account}/runbooks"
      assert {:error, {:live_redirect, %{to: ^destination}}} = render_click(lv, "save", %{})

      assert %Runbook{} = saved = Repo.one!(Runbook)
      assert saved.live_version == 1
      assert saved.definition == canonical_definition(valid_draft())
      assert saved.draft_definition == canonical_definition(edited)

      # The unpublished change is what the editor reopens; the rail names the
      # release it replaces and the number Publish will mint.
      {:ok, reopened, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      assert has_element?(reopened, "#runbook-lifecycle-desktop", "Published")
      assert has_element?(reopened, "#runbook-lifecycle-desktop", "Next")
      assert has_element?(reopened, "#runbook-lifecycle-desktop", "v2")
      assert has_element?(reopened, "#discard-runbook-draft")

      assert has_element?(
               reopened,
               ~s|button[aria-label="Discard changes"][class~="text-amber-200"]:not([disabled])|
             )
    end

    test "an unpublished change written elsewhere is refused, not overwritten", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      subject = owner_subject(user, account)

      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      # A second session saves over the same draft while this editor holds the
      # digest it opened.
      elsewhere = canonical_definition(valid_draft(inputs: [RunbookDraft.input()]))
      base_sha = Runbooks.definition_digest(runbook.draft_definition)
      attrs = %{"title" => "Fleet health", "draft_definition" => elsewhere}
      assert {:ok, _runbook} = Runbooks.save_draft(runbook, attrs, base_sha, subject)

      change(lv, valid_draft(title: "Fleet health rewritten"))
      html = render_click(lv, "save", %{})

      assert html =~ "This runbook changed elsewhere."
      assert Repo.one!(Runbook).draft_definition == elsewhere
    end

    test "the publish review shows what changes before the release is minted", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)

      published =
        [
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        ]
        |> Fixtures.Runbooks.create_runbook()
        |> Fixtures.Runbooks.publish_runbook()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      input =
        RunbookDraft.input()
        |> Map.merge(%{"id" => "incident_id", "description" => "Incident being worked"})

      change(lv, valid_draft(inputs: [input]))
      html = render_click(lv, "review_publish", %{})

      assert html =~ "These changes replace the published workflow."
      assert has_element?(lv, "#runbook-actions-desktop-review", "incident_id")
      assert has_element?(lv, "#runbook-actions-desktop-review-confirm", "Publish v2")
      refute html =~ "First release"

      # Reviewing changes nothing; the confirm is what publishes.
      assert Repo.one!(Runbook).live_version == 1

      destination = ~p"/app/#{account}/runbooks"

      assert {:error, {:live_redirect, %{to: ^destination}}} =
               render_click(lv, "publish", %{})

      assert %Runbook{} = live_runbook = Repo.one!(Runbook)
      assert live_runbook.live_version == 2
      assert live_runbook.draft_definition == nil

      releases = Repo.all(Release)
      published_versions = releases |> Enum.map(& &1.version) |> Enum.sort()

      assert published_versions == [1, 2]
      assert %Release{} = release = Enum.max_by(releases, & &1.version)
      assert release.definition == live_runbook.definition
    end

    test "cancelling the publish review leaves the unpublished change alone", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)

      published =
        [
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        ]
        |> Fixtures.Runbooks.create_runbook()
        |> Fixtures.Runbooks.publish_runbook()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      change(lv, valid_draft(inputs: [RunbookDraft.input()]))
      render_click(lv, "review_publish", %{})

      html = render_click(lv, "cancel_publish", %{})

      refute html =~ "These lines replace what runs today."
      assert has_element?(lv, "#runbook-actions-desktop-publish", "Publish")
      assert Repo.one!(Runbook).live_version == 1
    end

    test "discarding the unpublished change returns the editor to the live release", %{
      conn: conn,
      user: user,
      account: account
    } do
      arrange_current_action(account, user)
      live_definition = canonical_definition(valid_draft())

      published =
        [
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: live_definition
        ]
        |> Fixtures.Runbooks.create_runbook()
        |> Fixtures.Runbooks.publish_runbook()

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")

      change(lv, valid_draft(inputs: [Map.put(RunbookDraft.input(), "id", "incident_id")]))
      render_click(lv, "save", %{})

      {:ok, editing, html} = live(conn, ~p"/app/#{account}/runbooks/#{published.id}/edit")
      assert html =~ "incident_id"

      html = render_click(editing, "discard_draft", %{})

      assert html =~ "Unpublished changes discarded."
      refute html =~ "incident_id"
      assert has_element?(editing, ~s(button[aria-label="Discard changes"][disabled]))

      assert %Runbook{} = runbook = Repo.one!(Runbook)
      assert runbook.draft_definition == nil
      assert runbook.definition == live_definition
    end

    test "a never-published runbook offers no way to discard back to a release", %{
      conn: conn,
      user: user,
      account: account
    } do
      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft())
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")

      assert has_element?(lv, "#runbook-lifecycle-desktop", "Not published")
      refute has_element?(lv, "#discard-runbook-draft")

      # The domain refuses it too, so a crafted event cannot empty the editor.
      html = render_click(lv, "discard_draft", %{})

      assert html =~ "Could not discard these changes."
      assert Repo.one!(Runbook).draft_definition == canonical_definition(valid_draft())
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

      assert %Runbook{live_version: nil, definition: nil} = Repo.one!(Runbook)
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
      assert has_element?(lv, details, "from stdout at")
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

    test "output pickers show only streams and resolve the extractor to a valid source", %{
      conn: conn,
      user: user,
      account: account
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"healthy" => %{"type" => "boolean"}},
        "required" => ["healthy"],
        "additionalProperties" => false
      }

      arrange_current_action(account, user, output_schema: schema)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")
      change(lv, valid_draft())
      render_click(lv, "add_output", %{"stage" => "0", "step" => "0"})

      source = ~s(select[name="draft[stages][0][steps][0][outputs][0][source]"])

      assert has_element?(
               lv,
               source <> ~s( option[value="structured_output"][selected]),
               "stdout"
             )

      assert has_element?(lv, source <> ~s( option[value="stderr"]), "stderr")
      options = lv |> render() |> LazyHTML.from_document() |> LazyHTML.query(source <> " option")
      assert Enum.count(options) == 2
      refute has_element?(lv, source, "Structured output")
      refute has_element?(lv, "#runbook-stage-0-step-0-outputs", "must contain valid JSON")

      output = %{
        RunbookDraft.output()
        | "source" => "structured_output",
          "extract_type" => "regex"
      }

      draft =
        put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0), "outputs"], [output])

      change(lv, draft)

      assert has_element?(lv, source <> ~s( option[value="stdout"][selected]), "stdout")
      refute has_element?(lv, source <> ~s( option[value="structured_output"]))
      refute render(lv) =~ "Structured output requires a JSON Pointer extractor."
    end

    test "loaded output bindings survive form posts and deletion of unnamed siblings", %{
      conn: conn,
      user: user,
      account: account
    } do
      schema = %{
        "type" => "object",
        "properties" => %{"healthy" => %{"type" => "boolean"}},
        "required" => ["healthy"],
        "additionalProperties" => false
      }

      arrange_current_action(account, user, output_schema: schema)

      outputs = [
        %{RunbookDraft.output() | "id" => "validated", "source" => "structured_output"},
        %{RunbookDraft.output() | "id" => "raw", "source" => "stdout"}
      ]

      draft =
        put_in(valid_draft(), ["stages", Access.at(0), "steps", Access.at(0), "outputs"], outputs)

      definition = canonical_definition(draft)

      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          definition: definition
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/#{runbook.id}/edit")
      lv |> form("#runbook-editor-form") |> render_change()

      json =
        lv
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#runbook-canonical-json")
        |> LazyHTML.text()
        |> Jason.decode!()

      assert json == definition

      unnamed = Enum.map(outputs, &Map.put(&1, "id", ""))
      draft = put_in(draft, ["stages", Access.at(0), "steps", Access.at(0), "outputs"], unnamed)
      change(lv, draft)
      render_click(lv, "remove_output", %{"stage" => "0", "step" => "0", "index" => "0"})

      source = ~s(select[name="draft[stages][0][steps][0][outputs][0][source]"])
      assert has_element?(lv, source <> ~s( option[value="stdout"][selected]))
      refute has_element?(lv, source <> ~s( option[value="structured_output"]))
    end

    test "a stage and an open step lead with the identifier they were given", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/runbooks/new")

      assert has_element?(lv, ~s(input[name="draft[stages][0][id]"][value=""]))

      assert has_element?(
               lv,
               ~s(input[name="draft[stages][0][steps][0][id]"][value=""])
             )

      assert has_element?(lv, "#runbook-stage-0 h3", "Stage 1")
      assert has_element?(lv, "#runbook-stage-0", "Stage 1 · sequential")
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

      runbook =
        Fixtures.Runbooks.create_runbook(
          account_id: account.id,
          created_by_id: user.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(draft)
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
      assert has_element?(lv, summary, "All available runners in default")
      refute has_element?(lv, ~s|#{summary} [data-target-scope-icon]|)

      # The phrase says what it is, so no glyph labels it.
      refute has_element?(lv, summary, "→")
      assert has_element?(lv, summary, "uptime")
      assert has_element?(lv, details, "from run-time input")
      assert has_element?(lv, details, "from stdout at")

      # An operator-supplied value reads like the name it belongs to.
      assert has_element?(lv, "#{details} span[class*='font-mono']", "config_path")
      assert has_element?(lv, "#{details} span[class*='font-mono']", "/healthy")
      assert has_element?(lv, "#{details} span[class*='font-mono']", "true")

      assert has_element?(
               lv,
               details,
               "repeat every 10s, for up to 12 attempts or 120s"
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
      input =
        RunbookDraft.input()
        |> Map.merge(%{
          "id" => "scope",
          "description" => "Incident scope",
          "type" => "enum",
          "enum_values" => [%{"value" => "database"}]
        })

      runbook =
        [
          account_id: account.id,
          created_by_id: owner.id,
          title: "Fleet health",
          slug: "fleet-health",
          definition: canonical_definition(valid_draft(inputs: [input]))
        ]
        |> Fixtures.Runbooks.create_runbook()
        |> Fixtures.Runbooks.publish_runbook()

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
      assert has_element?(lv, "#runbook-lifecycle-desktop", "Published")
      assert has_element?(lv, "#runbook-lifecycle-desktop", "v1")

      assert :binary.match(html, ~s(id="runbook-lifecycle-desktop")) <
               :binary.match(html, ~s(name="draft[title]"))

      assert has_element?(lv, "#runbook-editor-form input[disabled]")
      refute has_element?(lv, "button", "Save draft")
      refute has_element?(lv, "button", "Publish")
      refute has_element?(lv, "#delete-runbook")
      refute has_element?(lv, "#discard-runbook-draft")
      refute has_element?(lv, "button", "Add input")
      refute has_element?(lv, ~s(button[aria-label="Remove input"]))

      # Disclosure is inspection, so it stays available and says so.
      assert has_element?(lv, ~s|button[phx-click="toggle_step"]|, "Show")
      render_click(lv, "toggle_step", %{"stage" => "0", "step" => "0"})
      assert has_element?(lv, ~s|button[phx-click="toggle_step"]|, "Hide")

      # The hidden controls are not the gate: a crafted event is refused too.
      for event <- ["save", "review_publish", "publish", "discard_draft", "delete"] do
        assert render_click(lv, event, %{}) =~ "You don&#39;t have permission to do that."
      end

      # Every STRUCTURAL mutation funnels through mutate/2, whose head refuses
      # on read_only?. Exercise each with a crafted event and prove the
      # rendered draft did not move — the flash text may differ per event
      # (add_target validates its target first), but no event may mutate.
      structural = %{
        "draft_changed" => %{"draft" => %{"title" => "Hijacked"}},
        "add_input" => %{},
        "remove_input" => %{"index" => "0"},
        "add_enum_value" => %{"index" => "0"},
        "toggle_enum_default" => %{"input" => "0", "enum" => "0"},
        "remove_enum_value" => %{"input" => "0", "enum" => "0"},
        "add_stage" => %{},
        "remove_stage" => %{"index" => "0"},
        "move_stage" => %{"index" => "0", "direction" => "down"},
        "add_step" => %{"stage" => "0"},
        "add_target" => %{
          "stage" => "0",
          "step" => "0",
          "target" => "group:default",
          "selection" => "all"
        },
        "remove_target" => %{"stage" => "0", "step" => "0", "target" => "group:default"},
        "remove_step" => %{"stage" => "0", "step" => "0"},
        "move_step" => %{"stage" => "0", "step" => "0", "direction" => "down"},
        "add_output" => %{"stage" => "0", "step" => "0"},
        "remove_output" => %{"stage" => "0", "step" => "0", "index" => "0"},
        "add_success" => %{"stage" => "0", "step" => "0"},
        "remove_success" => %{"stage" => "0", "step" => "0", "index" => "0"}
      }

      # Compare the FORM subtree, not the whole page: the refusal itself puts
      # up a flash, so whole-page equality would fail on the very guard working.
      form_render = fn -> lv |> element("#runbook-editor-form") |> render() end
      before_render = form_render.()

      for {event, params} <- structural do
        render_click(lv, event, params)
      end

      assert form_render.() == before_render,
             "a structural event mutated a read-only editor"

      # Completeness: the table above must cover every handler the module
      # defines, minus the persistence events asserted above and the three
      # UI-only ones. A 24th handler added without a read_only? guard fails
      # here until it is classified.
      source =
        File.read!(
          Path.join([
            File.cwd!(),
            "lib/emisar_web/live/runbook_editor_live.ex"
          ])
        )

      declared =
        Regex.scan(~r/def handle_event\(\s*"([a-z_]+)"/, source)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      classified =
        MapSet.new(
          Map.keys(structural) ++
            ["save", "review_publish", "publish", "discard_draft", "delete"] ++
            ["cancel_publish", "toggle_panel", "toggle_step", "load_action_pool"]
        )

      assert MapSet.equal?(declared, classified),
             "unclassified editor events: #{inspect(MapSet.difference(declared, classified) |> MapSet.to_list())}"

      assert %Runbook{live_version: 1, deleted_at: nil} = Repo.one!(Runbook)
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

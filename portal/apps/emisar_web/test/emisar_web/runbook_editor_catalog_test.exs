defmodule EmisarWeb.RunbookEditorCatalogTest do
  use ExUnit.Case, async: true
  alias Emisar.{Fixtures, Runbooks}
  alias EmisarWeb.{RunbookDraft, RunbookEditorCatalog}

  @schema %{
    "type" => "object",
    "properties" => %{"healthy" => %{"type" => "boolean"}},
    "required" => ["healthy"],
    "additionalProperties" => false
  }

  defp projection(schema) do
    Fixtures.Runbooks.build_editor_projection(
      [%{group: "default"}],
      [
        %{
          pack_id: "demo",
          action_id: "demo.inspect",
          descriptor: %{"risk" => "low", "output_schema" => schema}
        }
      ]
    )
  end

  defp step(outputs) do
    Map.merge(RunbookDraft.step(), %{
      "pack_id" => "demo",
      "action" => "demo.inspect",
      "target_refs" => ["group:default"],
      "outputs" => outputs
    })
  end

  defp output(source, extractor \\ "json_pointer") do
    Map.merge(RunbookDraft.output(), %{
      "id" => "healthy",
      "source" => source,
      "extract_type" => extractor,
      "expression" => "/healthy"
    })
  end

  test "new stdout JSON bindings use the common action schema when available" do
    for {schema, source} <- [{@schema, "structured_output"}, {nil, "stdout"}] do
      catalog = projection(schema)
      new = output("stdout")

      assert {:ok, action} =
               Runbooks.editor_action(catalog, ["group:default"], "all", "demo", "demo.inspect")

      assert action.output_schema == schema

      synced = RunbookEditorCatalog.sync_step(step([new]), step([]), catalog)
      assert synced["outputs"] == [Map.put(new, "source", source)]
    end
  end

  test "partial group access retains individual choices without presenting them as the whole group" do
    catalog = %{projection(@schema) | groups: []}
    [target] = catalog.targets

    for selection <- ["all", "random_one"] do
      options = RunbookEditorCatalog.target_options(catalog, ["group:default"], selection)
      saved = Enum.find(options, &(&1.value == "group:default"))
      assert saved.selected
      assert saved.unavailable
      refute saved.disabled
      refute saved.label =~ "online"
      assert Enum.any?(options, &(&1.value == "runner:" <> target.runner_ref))
      refute RunbookEditorCatalog.target_available?(catalog, "group:default")
      refute Enum.any?(options, &(&1.value == "group:default" and not &1[:unavailable]))
    end
  end

  test "every text extractor reads the selected text stream" do
    catalog = projection(@schema)

    for extractor <- ["contains", "grep", "regex"], source <- ["structured_output", "stderr"] do
      changed = output(source, extractor)
      synced = RunbookEditorCatalog.sync_step(step([changed]), step([output(source)]), catalog)
      expected_source = if source == "stderr", do: "stderr", else: "stdout"

      assert synced["outputs"] == [Map.put(changed, "source", expected_source)]
    end
  end

  test "source and method changes select validated stdout only for JSON Pointer" do
    catalog = projection(@schema)

    for previous <- [output("stdout", "regex"), output("stderr")] do
      synced = RunbookEditorCatalog.sync_step(step([output("stdout")]), step([previous]), catalog)
      assert synced["outputs"] == [output("structured_output")]
    end

    stderr = step([output("stderr")])

    assert RunbookEditorCatalog.sync_step(stderr, step([output("structured_output")]), catalog) ==
             stderr
  end

  test "loading or editing an unrelated field preserves each exact saved source" do
    for schema <- [@schema, nil], source <- ["structured_output", "stdout", "stderr"] do
      catalog = projection(schema)
      saved = step([output(source)])

      assert RunbookEditorCatalog.sync_step(saved, saved, catalog) == saved

      renamed = put_in(saved, ["outputs", Access.at(0), "id"], "status")
      assert RunbookEditorCatalog.sync_step(renamed, saved, catalog) == renamed

      edited = put_in(saved, ["outputs", Access.at(0), "expression"], "/status")
      assert RunbookEditorCatalog.sync_step(edited, saved, catalog) == edited
    end
  end

  test "renaming to another row's ID does not reselect its raw JSON binding" do
    raw = output("stdout")
    validated = Map.put(output("structured_output"), "id", "other")
    renamed = step([validated, Map.put(raw, "id", "other")])

    assert RunbookEditorCatalog.sync_step(renamed, step([validated, raw]), projection(@schema)) ==
             renamed
  end

  test "an unchanged invalid structured-output text binding is corrected to stdout" do
    for extractor <- ["contains", "grep", "regex"] do
      invalid = step([output("structured_output", extractor)])
      synced = RunbookEditorCatalog.sync_step(invalid, invalid, projection(@schema))

      assert synced["outputs"] == [output("stdout", extractor)]
    end
  end

  test "unresolved targets cannot supply an output schema" do
    catalog = projection(@schema)
    new = %{step([output("stdout")]) | "target_refs" => ["group:missing"]}

    assert RunbookEditorCatalog.sync_step(new, step([]), catalog) == new

    saved = step([output("structured_output")])
    assert RunbookEditorCatalog.sync_step(saved, saved, %Runbooks.EditorProjection{}) == saved
  end

  test "changing to an untyped action uses stdout without rewriting the saved binding" do
    previous = %{step([output("structured_output")]) | "action" => "demo.typed"}
    changed = step([output("structured_output")])

    synced = RunbookEditorCatalog.sync_step(changed, previous, projection(nil))
    assert synced["outputs"] == [output("stdout")]
    assert previous["outputs"] == [output("structured_output")]
  end
end

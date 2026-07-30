defmodule EmisarWeb.RunbookEditorLive do
  @moduledoc """
  Structured authoring for the one strict runbook v1 definition.

  Form state is converted by `EmisarWeb.RunbookDraft`; save, publish, console
  preflight, and MCP all reach the same Runbooks validator/compiler.
  """
  use EmisarWeb, :live_view
  alias Emisar.{Catalog, Runbooks, Runners}
  alias EmisarWeb.{LiveForm, Permissions, RunbookDraft, RunbookEditorCatalog}

  @preview_delay_ms 350

  def mount(params, _session, socket) do
    if connected?(socket),
      do: apply_action(socket, socket.assigns.live_action, params),
      else: mount_disconnected(socket, socket.assigns.live_action)
  end

  defp mount_disconnected(socket, :new), do: apply_action(socket, :new, %{})

  defp mount_disconnected(socket, :edit) do
    draft = RunbookDraft.new()

    {:ok,
     socket
     |> assign(:loaded?, false)
     |> assign(:page_title, "Runbook")
     |> assign(:runbook, nil)
     |> assign(:read_only?, true)
     |> assign(:draft, draft)
     |> assign(:baseline, RunbookDraft.fingerprint(draft))
     |> assign(:dirty?, false)
     |> assign(:definition_issues, [])
     |> assign(:open_panels, MapSet.new())
     |> assign(:preview_generation, 0)
     |> assign(:preview, %{state: :idle, plan: nil, issues: [], checked_at: nil})
     |> assign_form(Runbooks.change_runbook())
     |> assign_empty_catalog()}
  end

  defp apply_action(socket, :new, _params) do
    draft = RunbookDraft.new()

    socket =
      socket
      |> assign(:loaded?, true)
      |> assign(:page_title, "New runbook")
      |> assign(:runbook, nil)
      |> assign(
        :read_only?,
        not Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject)
      )
      |> assign(:draft, draft)
      |> assign(:baseline, RunbookDraft.fingerprint(draft))
      |> assign(:dirty?, false)
      |> assign(:definition_issues, [])
      |> assign(:open_panels, MapSet.new())
      |> assign(:preview_generation, 0)
      |> assign(:preview, %{state: :idle, plan: nil, issues: [], checked_at: nil})
      |> assign_form(Runbooks.change_runbook())
      |> assign_empty_catalog()

    {:ok, load_catalog_and_validate(socket)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      {:ok, runbook} ->
        draft = RunbookDraft.from_runbook(runbook)

        socket =
          socket
          |> assign(:loaded?, true)
          |> assign(:page_title, "Edit #{runbook.title}")
          |> assign(:runbook, runbook)
          |> assign(
            :read_only?,
            not Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject)
          )
          |> assign(:draft, draft)
          |> assign(:baseline, RunbookDraft.fingerprint(draft))
          |> assign(:dirty?, false)
          |> assign(:definition_issues, [])
          |> assign(:open_panels, MapSet.new())
          |> assign(:preview_generation, 0)
          |> assign(:preview, %{state: :idle, plan: nil, issues: [], checked_at: nil})
          |> assign_form(
            Runbooks.change_runbook(%{
              "title" => runbook.title,
              "slug" => runbook.slug,
              "description" => runbook.description
            })
          )
          |> assign_empty_catalog()

        {:ok, load_catalog_and_validate(socket)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Runbook not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    end
  end

  defp assign_empty_catalog(socket) do
    socket
    |> assign(:catalog, %{
      actions: %{},
      target_labels: %{},
      target_options: [],
      target_runner_ids: %{}
    })
    |> assign(:catalog_load_error?, false)
  end

  defp load_catalog_and_validate(socket) do
    subject = socket.assigns.current_subject

    {runner_actions, actions_loaded?} =
      case Catalog.list_all_actions_for_account(subject) do
        {:ok, actions} -> {actions, true}
        {:error, _reason} -> {[], false}
      end

    {runners, runners_loaded?} =
      case Runners.list_all_runners_for_account(subject) do
        {:ok, rows} -> {rows, true}
        {:error, _reason} -> {[], false}
      end

    catalog = RunbookEditorCatalog.build(runner_actions, runners)
    draft = sync_draft_catalog(socket.assigns.draft, socket.assigns.draft, catalog)

    socket
    |> assign(:draft, draft)
    |> assign(:catalog, catalog)
    |> assign(:catalog_load_error?, not actions_loaded? or not runners_loaded?)
    |> validate_and_preview()
  end

  def handle_event("draft_changed", %{"draft" => params} = event_params, socket) do
    if socket.assigns.read_only? do
      {:noreply, put_flash(socket, :error, "This runbook is read-only for your role.")}
    else
      previous = socket.assigns.draft

      draft =
        params
        |> normalize_draft_params()
        |> sync_draft_catalog(previous, socket.assigns.catalog)

      changeset =
        Runbooks.change_runbook(%{
          "title" => draft["title"],
          "slug" => draft["slug"],
          "description" => draft["description"]
        })
        |> LiveForm.on_change(event_params)

      {:noreply,
       socket
       |> assign(:draft, draft)
       |> assign(
         :open_panels,
         open_changed_enum_panels(socket.assigns.open_panels, previous, draft)
       )
       |> assign_form(changeset)
       |> mark_dirty()
       |> validate_and_preview()}
    end
  end

  def handle_event("add_input", _params, socket) do
    mutate(socket, &append_input/1)
  end

  def handle_event("remove_input", %{"index" => index}, socket) do
    mutate(
      socket,
      &Map.update!(&1, "inputs", fn inputs -> List.delete_at(inputs, safe_index(index)) end)
    )
  end

  def handle_event("add_enum_value", %{"index" => index}, socket) do
    mutate(socket, fn draft ->
      Map.update!(draft, "inputs", fn inputs ->
        List.update_at(inputs, safe_index(index), fn input ->
          Map.update!(input, "enum_values", &(&1 ++ [%{"value" => ""}]))
        end)
      end)
    end)
  end

  def handle_event(
        "remove_enum_value",
        %{"input" => input_index, "value" => value_index},
        socket
      ) do
    mutate(socket, fn draft ->
      Map.update!(draft, "inputs", fn inputs ->
        List.update_at(inputs, safe_index(input_index), fn input ->
          Map.update!(input, "enum_values", &List.delete_at(&1, safe_index(value_index)))
        end)
      end)
    end)
  end

  def handle_event("add_stage", _params, socket) do
    mutate(socket, &append_stage/1)
  end

  def handle_event("remove_stage", %{"index" => index}, socket) do
    mutate(
      socket,
      &Map.update!(&1, "stages", fn stages -> List.delete_at(stages, safe_index(index)) end)
    )
  end

  def handle_event("move_stage", %{"index" => index, "direction" => direction}, socket) do
    mutate(socket, &Map.update!(&1, "stages", fn stages -> move(stages, index, direction) end))
  end

  def handle_event("add_step", %{"stage" => stage_index}, socket) do
    mutate(socket, fn draft ->
      update_stage(
        draft,
        stage_index,
        &Map.update!(&1, "steps", fn steps -> steps ++ [RunbookDraft.step()] end)
      )
    end)
  end

  def handle_event(
        "add_target",
        %{"stage" => stage_index, "step" => step_index, "target" => target},
        socket
      ) do
    if Map.has_key?(socket.assigns.catalog.target_runner_ids, target) do
      mutate_step(socket, stage_index, step_index, fn step ->
        refs = step["target_refs"] || []

        if target in refs or length(refs) >= 16,
          do: step,
          else: Map.put(step, "target_refs", refs ++ [target])
      end)
    else
      {:noreply, put_flash(socket, :error, "Choose a current runner or group.")}
    end
  end

  def handle_event(
        "remove_target",
        %{"stage" => stage_index, "step" => step_index, "target" => target},
        socket
      ) do
    mutate_step(
      socket,
      stage_index,
      step_index,
      &Map.update!(&1, "target_refs", fn refs -> List.delete(refs, target) end)
    )
  end

  def handle_event("remove_step", %{"stage" => stage_index, "step" => step_index}, socket) do
    mutate(socket, fn draft ->
      update_stage(
        draft,
        stage_index,
        &Map.update!(&1, "steps", fn steps -> List.delete_at(steps, safe_index(step_index)) end)
      )
    end)
  end

  def handle_event(
        "move_step",
        %{"stage" => stage_index, "step" => step_index, "direction" => direction},
        socket
      ) do
    mutate(socket, fn draft ->
      update_stage(
        draft,
        stage_index,
        &Map.update!(&1, "steps", fn steps -> move(steps, step_index, direction) end)
      )
    end)
  end

  def handle_event("add_output", %{"stage" => stage_index, "step" => step_index}, socket) do
    mutate_step(socket, stage_index, step_index, &append_output/1)
  end

  def handle_event(
        "remove_output",
        %{"stage" => stage_index, "step" => step_index, "index" => index},
        socket
      ) do
    mutate_step(socket, stage_index, step_index, fn step ->
      Map.update!(step, "outputs", &List.delete_at(&1, safe_index(index)))
    end)
  end

  def handle_event("add_success", %{"stage" => stage_index, "step" => step_index}, socket) do
    step =
      socket.assigns.draft["stages"]
      |> Enum.at(safe_index(stage_index), %{})
      |> Map.get("steps", [])
      |> Enum.at(safe_index(step_index), %{})

    if step["outputs"] in [nil, []],
      do: {:noreply, put_flash(socket, :error, "Add an extracted output first.")},
      else: mutate_step(socket, stage_index, step_index, &append_success/1)
  end

  def handle_event(
        "remove_success",
        %{"stage" => stage_index, "step" => step_index, "index" => index},
        socket
      ) do
    mutate_step(socket, stage_index, step_index, fn step ->
      Map.update!(step, "success", &List.delete_at(&1, safe_index(index)))
    end)
  end

  def handle_event("save", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &save(&1, false)
    )
  end

  def handle_event("publish", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &save(&1, true)
    )
  end

  def handle_event("delete", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &delete_runbook/1
    )
  end

  def handle_event("toggle_panel", %{"key" => key}, socket) do
    {:noreply, update(socket, :open_panels, &toggle_panel(&1, key))}
  end

  def handle_info(
        {:runbook_preview, generation},
        %{assigns: %{preview_generation: generation}} = socket
      ) do
    {:noreply, run_preview(socket)}
  end

  def handle_info({:runbook_preview, _stale_generation}, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp mutate(%{assigns: %{read_only?: true}} = socket, _fun),
    do: {:noreply, put_flash(socket, :error, "This runbook is read-only for your role.")}

  defp mutate(socket, fun) do
    {:noreply,
     socket
     |> assign(:draft, fun.(socket.assigns.draft))
     |> mark_dirty()
     |> validate_and_preview()}
  end

  defp mutate_step(socket, stage_index, step_index, fun) do
    mutate(socket, &update_step(&1, stage_index, step_index, fun))
  end

  defp append_input(draft) do
    Map.update!(draft, "inputs", &(&1 ++ [RunbookDraft.input()]))
  end

  defp append_stage(draft) do
    Map.update!(draft, "stages", &(&1 ++ [RunbookDraft.stage()]))
  end

  defp append_output(step) do
    Map.update!(step, "outputs", &(&1 ++ [RunbookDraft.output()]))
  end

  defp append_success(step) do
    output_id = step["outputs"] |> List.first(%{}) |> Map.get("id", "")
    condition = Map.put(RunbookDraft.success(), "output", output_id)
    Map.update!(step, "success", &(&1 ++ [condition]))
  end

  defp update_step(draft, stage_index, step_index, fun) do
    update_stage(draft, stage_index, fn stage ->
      steps = List.update_at(stage["steps"], safe_index(step_index), fun)
      Map.put(stage, "steps", steps)
    end)
  end

  defp update_stage(draft, stage_index, fun) do
    Map.update!(draft, "stages", &List.update_at(&1, safe_index(stage_index), fun))
  end

  defp move(values, index, direction) do
    index = safe_index(index)
    destination = if direction == "up", do: index - 1, else: index + 1

    if index < length(values) and destination >= 0 and destination < length(values) do
      value = Enum.at(values, index)
      values |> List.delete_at(index) |> List.insert_at(destination, value)
    else
      values
    end
  end

  defp safe_index(value) do
    case Integer.parse(to_string(value)) do
      {index, ""} when index >= 0 -> index
      _ -> 1_000_000_000
    end
  end

  defp toggle_panel(panels, key) do
    if MapSet.member?(panels, key), do: MapSet.delete(panels, key), else: MapSet.put(panels, key)
  end

  defp open_changed_enum_panels(panels, previous, draft) do
    draft["inputs"]
    |> Enum.with_index()
    |> Enum.reduce(panels, fn {input, index}, open ->
      previous_type = get_in(previous, ["inputs", Access.at(index), "type"])

      if input["type"] == "enum" and previous_type != "enum",
        do: MapSet.put(open, "input-constraints-#{index}"),
        else: open
    end)
  end

  defp validate_and_preview(socket) do
    definition = RunbookDraft.definition(socket.assigns.draft)

    case Runbooks.validate_definition(definition, socket.assigns.current_subject) do
      {:ok, _definition} ->
        socket
        |> assign(:definition_issues, [])
        |> schedule_preview()

      {:error, issues} when is_list(issues) ->
        socket
        |> assign(:definition_issues, issues)
        |> assign(:preview, %{
          state: :blocked,
          plan: nil,
          issues: issues,
          checked_at: DateTime.utc_now()
        })

      {:error, _reason} ->
        socket
        |> assign(:definition_issues, [])
        |> assign(:preview, %{state: :unavailable, plan: nil, issues: [], checked_at: nil})
    end
  end

  defp schedule_preview(%{assigns: %{read_only?: true}} = socket) do
    assign(socket, :preview, %{state: :unavailable, plan: nil, issues: [], checked_at: nil})
  end

  defp schedule_preview(socket) do
    generation = socket.assigns.preview_generation + 1
    Process.send_after(self(), {:runbook_preview, generation}, @preview_delay_ms)

    socket
    |> assign(:preview_generation, generation)
    |> assign(:preview, %{socket.assigns.preview | state: :loading})
  end

  defp run_preview(socket) do
    definition = RunbookDraft.definition(socket.assigns.draft)

    case Runbooks.preview_definition_plan(definition, socket.assigns.current_subject) do
      {:ok, %{plan: plan}} ->
        assign(socket, :preview, %{
          state: :ready,
          plan: plan,
          issues: [],
          checked_at: DateTime.utc_now()
        })

      {:error, issues} when is_list(issues) ->
        assign(socket, :preview, %{
          state: :blocked,
          plan: nil,
          issues: issues,
          checked_at: DateTime.utc_now()
        })

      {:error, _reason} ->
        assign(socket, :preview, %{
          state: :unavailable,
          plan: nil,
          issues: [],
          checked_at: DateTime.utc_now()
        })
    end
  end

  defp mark_dirty(socket) do
    assign(
      socket,
      :dirty?,
      RunbookDraft.fingerprint(socket.assigns.draft) != socket.assigns.baseline
    )
  end

  defp save(socket, publish?) do
    definition = RunbookDraft.definition(socket.assigns.draft)

    cond do
      not socket.assigns.dirty? and not publishable_saved_draft?(socket, publish?) ->
        {:noreply, socket}

      not socket.assigns.form.source.valid? ->
        {:noreply, put_flash(socket, :error, "Fix the runbook details before saving.")}

      publish? and
          (socket.assigns.definition_issues != [] or socket.assigns.preview.state != :ready) ->
        {:noreply, put_flash(socket, :error, "Current preflight must pass before publishing.")}

      true ->
        attrs = %{
          "title" => socket.assigns.draft["title"],
          "name" => socket.assigns.draft["title"],
          "slug" => derive_slug(socket.assigns.draft["slug"], socket.assigns.draft["title"]),
          "description" => socket.assigns.draft["description"],
          "definition" => definition,
          "status" => "draft"
        }

        case persist(socket, attrs, publish?) do
          {:ok, runbook} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               if(publish?, do: "Runbook published.", else: draft_message(runbook))
             )
             |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not save this runbook.")}
        end
    end
  end

  defp persist(%{assigns: %{runbook: nil}} = socket, attrs, true),
    do: Runbooks.create_published_runbook(attrs, socket.assigns.current_subject)

  defp persist(%{assigns: %{runbook: nil}} = socket, attrs, false),
    do: Runbooks.create_runbook(attrs, socket.assigns.current_subject)

  defp persist(
         %{assigns: %{runbook: %{status: :draft} = runbook, dirty?: false}} = socket,
         _attrs,
         true
       ),
       do: Runbooks.publish(runbook, socket.assigns.current_subject)

  defp persist(%{assigns: %{runbook: runbook}} = socket, attrs, publish?) do
    with {:ok, new_version} <-
           Runbooks.save_new_version(runbook, attrs, socket.assigns.current_subject) do
      if publish?,
        do: Runbooks.publish(new_version, socket.assigns.current_subject),
        else: {:ok, new_version}
    end
  end

  defp draft_message(%{version: version}) when version > 1, do: "Draft v#{version} saved."
  defp draft_message(_runbook), do: "Draft saved."

  defp delete_runbook(%{assigns: %{runbook: nil}} = socket), do: {:noreply, socket}

  defp delete_runbook(socket) do
    case Runbooks.delete_runbook(socket.assigns.runbook, socket.assigns.current_subject) do
      {:ok, _runbook} ->
        {:noreply,
         socket
         |> put_flash(:info, "Runbook deleted.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete this runbook.")}
    end
  end

  defp derive_slug(slug, title) do
    case String.trim(slug || "") do
      "" -> Emisar.Slug.slugify(title || "", max_length: 79)
      value -> value
    end
  end

  defp assign_form(socket, changeset),
    do: assign(socket, :form, to_form(changeset, as: "runbook"))

  defp sync_draft_catalog(draft, previous, catalog) do
    stages =
      draft["stages"]
      |> Enum.with_index()
      |> Enum.map(fn {stage, stage_index} ->
        previous_stage = Enum.at(previous["stages"] || [], stage_index, %{})

        steps =
          stage["steps"]
          |> Enum.with_index()
          |> Enum.map(fn {step, step_index} ->
            previous_step = Enum.at(previous_stage["steps"] || [], step_index, %{})
            sync_step_catalog(step, previous_step, catalog)
          end)

        Map.put(stage, "steps", steps)
      end)

    Map.put(draft, "stages", stages)
  end

  defp sync_step_catalog(step, previous, catalog) do
    RunbookEditorCatalog.sync_step(step, previous, catalog)
  end

  defp normalize_draft_params(params) do
    %{
      "title" => params["title"] || "",
      "slug" => params["slug"] || "",
      "description" => params["description"] || "",
      "context_markdown" => params["context_markdown"] || "",
      "inputs" => params["inputs"] |> indexed() |> Enum.map(&normalize_input/1),
      "stages" => params["stages"] |> indexed() |> Enum.map(&normalize_stage/1)
    }
  end

  defp normalize_input(input) do
    RunbookDraft.input()
    |> Map.merge(Map.take(input, Map.keys(RunbookDraft.input())))
    |> Map.put(
      "enum_values",
      input["enum_values"]
      |> indexed()
      |> Enum.map(&%{"value" => &1["value"] || ""})
    )
  end

  defp normalize_stage(stage) do
    RunbookDraft.stage()
    |> Map.merge(Map.take(stage, ~w[id title mode max_parallel]))
    |> Map.put("steps", stage["steps"] |> indexed() |> Enum.map(&normalize_step/1))
  end

  defp normalize_step(step) do
    {pack_id, action_id} =
      RunbookEditorCatalog.split_action_value(
        step["action_choice"] ||
          RunbookEditorCatalog.action_value(step["pack_id"], step["action"])
      )

    RunbookDraft.step()
    |> Map.merge(Map.take(step, ~w[id target_refs target_candidate wait]))
    |> Map.put("pack_id", pack_id)
    |> Map.put("action", action_id)
    |> Map.put("target_refs", List.wrap(step["target_refs"]))
    |> Map.put("args", step["args"] |> indexed() |> Enum.map(&normalize_argument/1))
    |> Map.put("outputs", step["outputs"] |> indexed() |> Enum.map(&normalize_output/1))
    |> Map.put("success", step["success"] |> indexed() |> Enum.map(&normalize_success/1))
    |> Map.put("wait", Map.merge(RunbookDraft.step()["wait"], step["wait"] || %{}))
  end

  defp normalize_argument(argument) do
    Map.merge(
      RunbookDraft.argument(),
      Map.take(argument, ~w[name type required sensitive source value ref])
    )
  end

  defp normalize_output(output) do
    Map.merge(
      RunbookDraft.output(),
      Map.take(output, ~w[id source sensitive extract_type expression capture])
    )
  end

  defp normalize_success(success),
    do: Map.merge(RunbookDraft.success(), Map.take(success, ~w[output operator value]))

  defp indexed(nil), do: []
  defp indexed(values) when is_list(values), do: values

  defp indexed(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> safe_index(key) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp publishable_saved_draft?(%{assigns: %{runbook: %{status: :draft}}}, true), do: true
  defp publishable_saved_draft?(_socket, _publish?), do: false

  def render(assigns), do: EmisarWeb.RunbookEditorComponents.render(assigns)
end

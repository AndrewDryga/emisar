defmodule EmisarWeb.RunbookEditorLive do
  @moduledoc """
  Visual runbook step builder. Each step is one action dispatch:
  `{id, action_id, runner_selector: {kind, value}, args: [{key, value},
  ...]}`. Steps reorder via Move up / Move down buttons (no JS hook
  needed). Form state lives in `socket.assigns.steps` as a list of
  maps; saving flattens it back to the JSON shape `Runbooks.engine`
  understands: `%{"steps" => [...]}`.
  """
  use EmisarWeb, :live_view

  alias Emisar.{Catalog, Runbooks}
  alias Emisar.Runbooks.Runbook
  alias EmisarWeb.Permissions

  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New runbook")
    |> assign(:runbook, nil)
    |> assign(:title, "")
    |> assign(:slug, "")
    |> assign(:description, "")
    |> assign(:steps, [example_action_step()])
    |> assign_catalog()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Runbooks.fetch_runbook_by_id(id, socket.assigns.current_subject) do
      {:ok, runbook} ->
        raw_steps = get_in(runbook.definition || %{}, ["steps"]) || []

        socket
        |> assign(:page_title, "Edit runbook")
        |> assign(:runbook, runbook)
        |> assign(:title, runbook.title || "")
        |> assign(:slug, runbook.slug || "")
        |> assign(:description, runbook.description || "")
        |> assign(:steps, Enum.map(raw_steps, &from_raw_step/1))
        |> assign_catalog()

      {:error, _} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/runbooks")
    end
  end

  defp assign_catalog(socket) do
    {:ok, runner_actions, _} = Catalog.list_actions_for_account(socket.assigns.current_subject)

    actions =
      runner_actions |> Enum.map(& &1.action_id) |> Enum.uniq() |> Enum.sort()

    # Build action_id → [arg_name, ...] for the rich arg picker. Same
    # action may be on multiple runners; merge their advertised arg
    # sets so the picker shows the union. (The pack catalog is the
    # source of truth — runner advertisements are just our local
    # mirror of it.)
    args_by_action =
      runner_actions
      |> Enum.reduce(%{}, fn ra, acc ->
        names =
          ra.args_schema
          |> Map.get("args", [])
          |> Enum.map(&Map.get(&1, "name"))
          |> Enum.reject(&is_nil/1)

        Map.update(acc, ra.action_id, MapSet.new(names), &MapSet.union(&1, MapSet.new(names)))
      end)
      |> Map.new(fn {id, set} -> {id, set |> MapSet.to_list() |> Enum.sort()} end)

    socket
    |> assign(:catalog_actions, actions)
    |> assign(:args_by_action, args_by_action)
  end

  # -- Events ---------------------------------------------------------

  def handle_event("meta_change", params, socket) do
    {:noreply,
     socket
     |> assign(:title, params["title"] || socket.assigns.title)
     |> assign(:slug, params["slug"] || socket.assigns.slug)
     |> assign(:description, params["description"] || socket.assigns.description)}
  end

  def handle_event("step_change", %{"index" => idx} = params, socket) do
    i = String.to_integer(idx)

    # Form input is named `step_id` to avoid collision with the form
    # element's HTML id — remap to the canonical "id" key here.
    params =
      params
      |> Map.put("id", params["step_id"] || params["id"])
      |> Map.take(~w(id action_id selector_kind selector_value))

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        step
        |> Map.merge(params)
        |> maybe_autoderive_step_id(step)
      end)

    {:noreply, assign(socket, :steps, steps)}
  end

  def handle_event("add_action_step", _params, socket) do
    {:noreply, assign(socket, :steps, socket.assigns.steps ++ [example_action_step()])}
  end

  def handle_event("remove_step", %{"index" => idx}, socket) do
    i = String.to_integer(idx)
    {:noreply, assign(socket, :steps, List.delete_at(socket.assigns.steps, i))}
  end

  def handle_event("move_step", %{"index" => idx, "dir" => dir}, socket) do
    i = String.to_integer(idx)
    target = if dir == "up", do: i - 1, else: i + 1
    steps = socket.assigns.steps

    cond do
      target < 0 or target >= length(steps) ->
        {:noreply, socket}

      true ->
        step = Enum.at(steps, i)
        steps = steps |> List.delete_at(i) |> List.insert_at(target, step)
        {:noreply, assign(socket, :steps, steps)}
    end
  end

  def handle_event("add_arg", %{"index" => idx}, socket) do
    i = String.to_integer(idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        Map.put(step, "args", args ++ [%{"key" => "", "value" => ""}])
      end)

    {:noreply, assign(socket, :steps, steps)}
  end

  def handle_event("remove_arg", %{"index" => idx, "arg" => arg_idx}, socket) do
    i = String.to_integer(idx)
    a = String.to_integer(arg_idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        Map.put(step, "args", List.delete_at(args, a))
      end)

    {:noreply, assign(socket, :steps, steps)}
  end

  def handle_event("arg_change", %{"index" => idx, "arg" => arg_idx} = params, socket) do
    i = String.to_integer(idx)
    a = String.to_integer(arg_idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        updated = List.update_at(args, a, &Map.merge(&1, Map.take(params, ~w(key value))))
        Map.put(step, "args", updated)
      end)

    {:noreply, assign(socket, :steps, steps)}
  end

  def handle_event("save", _params, socket) do
    Permissions.gated(socket, :manage_runbooks, fn s -> save(s, publish?: false) end)
  end

  def handle_event("publish", _params, socket) do
    Permissions.gated(socket, :manage_runbooks, fn s -> save(s, publish?: true) end)
  end

  defp save(socket, publish?: publish?) do
    slug = derive_slug(socket.assigns.slug, socket.assigns.title)

    attrs = %{
      "title" => socket.assigns.title,
      "name" => socket.assigns.title,
      "slug" => slug,
      "description" => socket.assigns.description,
      "definition" => %{"steps" => Enum.map(socket.assigns.steps, &to_raw_step/1)},
      "status" => if(publish?, do: "published", else: "draft")
    }

    with {:ok, runbook} <- persist(socket, attrs),
         {:ok, runbook} <- maybe_publish(runbook, publish?, socket) do
      {:noreply,
       socket
       |> put_flash(:info, success_message(runbook, publish?))
       |> push_navigate(to: ~p"/app/runbooks")}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Could not save runbook: #{format_errors(cs)}")}
    end
  end

  defp persist(%{assigns: %{runbook: nil}} = socket, attrs),
    do: Runbooks.create_runbook(attrs, socket.assigns.current_subject)

  defp persist(%{assigns: %{runbook: %Runbook{} = rb}} = socket, attrs),
    do: Runbooks.save_new_version(rb, attrs, socket.assigns.current_subject)

  defp maybe_publish(%Runbook{} = rb, true, socket),
    do: Runbooks.publish(rb, socket.assigns.current_subject)

  defp maybe_publish(%Runbook{} = rb, false, _socket), do: {:ok, rb}

  defp success_message(_, true), do: "Runbook published."
  defp success_message(%{version: v}, false) when v > 1, do: "Draft v#{v} saved."
  defp success_message(_, false), do: "Draft saved."

  defp derive_slug(slug, title) do
    case String.trim(slug || "") do
      "" -> slugify(title)
      s -> s
    end
  end

  defp slugify(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 79)
  end

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end

  # Auto-derive Step ID from the chosen Action whenever the user
  # hasn't customised it yet. We detect "not customised" by matching
  # the autogenerated placeholder shape `step<digits>` that
  # `example_action_step/0` emits. Once the operator types a custom id,
  # changing the action leaves their id alone — same principle as
  # auto-slug fields that go quiet after a manual edit.
  defp maybe_autoderive_step_id(%{"id" => id, "action_id" => action_id} = next, previous)
       when is_binary(id) and is_binary(action_id) and action_id != "" do
    if placeholder_step_id?(id) and action_id != previous["action_id"] do
      Map.put(next, "id", slug_from_action(action_id))
    else
      next
    end
  end

  defp maybe_autoderive_step_id(step, _previous), do: step

  defp placeholder_step_id?(id), do: Regex.match?(~r/^step\d+$/, id)

  defp slug_from_action(action_id) do
    action_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end

  # -- Step shape conversions ----------------------------------------

  defp example_action_step,
    do: %{
      "id" => "step#{System.unique_integer([:positive])}",
      "type" => "action",
      "action_id" => "",
      "selector_kind" => "group",
      "selector_value" => "",
      "args" => []
    }

  # JSON → editor state
  defp from_raw_step(raw) when is_map(raw) do
    {kind, val} = selector_to_pair(raw["runner_selector"])

    %{
      "id" => raw["id"] || "step",
      "type" => "action",
      "action_id" => raw["action_id"] || "",
      "selector_kind" => kind,
      "selector_value" => val,
      "args" => args_to_pairs(raw["args"] || %{})
    }
  end

  defp selector_to_pair(%{"group" => g}) when is_binary(g), do: {"group", g}
  defp selector_to_pair(%{"runner_id" => r}) when is_binary(r), do: {"runner_id", r}
  defp selector_to_pair(_), do: {"group", ""}

  defp args_to_pairs(%{} = m) do
    Enum.map(m, fn {k, v} -> %{"key" => k, "value" => to_string(v)} end)
  end

  # Editor state → JSON
  defp to_raw_step(%{"type" => "action"} = step) do
    %{
      "id" => step["id"],
      "action_id" => step["action_id"],
      "runner_selector" => %{step["selector_kind"] => step["selector_value"]},
      "args" => pairs_to_args(step["args"] || [])
    }
  end

  defp pairs_to_args(pairs) do
    pairs
    |> Enum.reject(&blank?(&1["key"]))
    |> Enum.into(%{}, fn p -> {String.trim(p["key"]), p["value"] || ""} end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # -- Render --------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
    >
      <:title>
        <.back_link navigate={~p"/app/runbooks"}>Runbooks</.back_link>
        <%= if @runbook do %>
          Edit runbook <span class="font-mono text-base text-zinc-400">{@runbook.slug}</span>
          <span class="ml-2 text-sm font-normal text-zinc-500">v{@runbook.version}</span>
        <% else %>
          New runbook
        <% end %>
      </:title>
      <:actions>
        <.link
          navigate={~p"/app/runbooks"}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 text-sm font-medium text-zinc-300 hover:bg-zinc-900"
        >
          Cancel
        </.link>
      </:actions>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-[1fr_320px]">
        <section class="overflow-hidden rounded-xl border border-zinc-900 bg-zinc-950/40">
          <header class="flex items-center justify-between border-b border-zinc-900 px-5 py-3">
            <h2 class="text-sm font-semibold text-zinc-100">Steps</h2>
            <button
              type="button"
              phx-click="add_action_step"
              class="inline-flex items-center gap-1.5 rounded-lg border border-zinc-800 px-2.5 py-1.5 text-xs font-medium text-zinc-300 hover:border-indigo-500 hover:text-indigo-300"
            >
              <.icon name="hero-plus" class="h-3.5 w-3.5" /> Add step
            </button>
          </header>

          <div class="space-y-3 p-5">
            <div
              :if={@steps == []}
              class="rounded-lg border border-dashed border-zinc-800 p-8 text-center text-xs text-zinc-500"
            >
              No steps. Add an action step above to start.
            </div>

            <datalist id="catalog-actions">
              <option :for={a <- @catalog_actions} value={a}></option>
            </datalist>

            <%!-- Per-action arg datalists. Each renders separately so
                 the arg_editor input can target the right one via its
                 `list=` attribute, and the dropdown only suggests args
                 actually defined for that step's action. --%>
            <%= for {action_id, arg_names} <- @args_by_action do %>
              <datalist id={"args-#{datalist_id(action_id)}"}>
                <option :for={name <- arg_names} value={name}></option>
              </datalist>
            <% end %>

            <%= for {step, idx} <- Enum.with_index(@steps) do %>
              <.step_card
                step={step}
                index={idx}
                total={length(@steps)}
                args_by_action={@args_by_action}
              />
            <% end %>

            <div class="flex items-center justify-end gap-3 pt-2">
              <button
                type="button"
                phx-click="save"
                class="rounded-lg border border-zinc-800 px-4 py-2 text-sm font-medium text-zinc-200 hover:bg-zinc-900"
                phx-disable-with="Saving..."
              >
                Save draft
              </button>
              <.button type="button" phx-click="publish" phx-disable-with="Publishing...">
                Publish
              </.button>
            </div>
          </div>
        </section>

        <aside class="space-y-4">
          <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
            <h2 class="text-sm font-semibold text-zinc-100">Metadata</h2>

            <form phx-change="meta_change" class="mt-4 space-y-4">
              <div>
                <label
                  class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
                  for="runbook_title"
                >
                  Title
                </label>
                <input
                  type="text"
                  id="runbook_title"
                  name="title"
                  value={@title}
                  required
                  placeholder="e.g. Cassandra: rolling repair"
                  class={input_class()}
                />
              </div>

              <div>
                <label
                  class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
                  for="runbook_slug"
                >
                  Slug
                </label>
                <input
                  type="text"
                  id="runbook_slug"
                  name="slug"
                  value={@slug}
                  placeholder="auto from title"
                  class={[input_class(), "font-mono text-xs"]}
                />
              </div>

              <div>
                <label
                  class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500"
                  for="runbook_description"
                >
                  Description
                </label>
                <textarea
                  id="runbook_description"
                  name="description"
                  rows="4"
                  placeholder="Optional human-readable summary."
                  class={input_class()}
                ><%= @description %></textarea>
              </div>
            </form>
          </section>

          <section :if={@runbook} class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
            <h2 class="text-sm font-semibold text-zinc-100">Version</h2>
            <dl class="mt-3 space-y-2 text-xs text-zinc-400">
              <.kv label="Current">v{@runbook.version}</.kv>
              <.kv label="Status"><.status_badge status={@runbook.status} /></.kv>
              <.kv label="Saving creates">v{@runbook.version + 1}</.kv>
            </dl>
            <p :if={@runbook.status == "published"} class="mt-4 text-xs text-zinc-500 leading-relaxed">
              Published runbooks are immutable — saving creates a new draft version.
            </p>
          </section>
        </aside>
      </div>
    </.dashboard_shell>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :args_by_action, :map, required: true

  defp step_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-800 bg-black/30 p-4">
      <div class="flex items-center justify-between gap-3">
        <span class="font-mono text-xs text-zinc-500">Step #{@index + 1}</span>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="move_step"
            phx-value-index={@index}
            phx-value-dir="up"
            disabled={@index == 0}
            class="rounded p-1 text-zinc-500 hover:text-zinc-200 disabled:opacity-30"
            title="Move up"
            aria-label="Move up"
          >
            <.icon name="hero-arrow-up" class="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            phx-click="move_step"
            phx-value-index={@index}
            phx-value-dir="down"
            disabled={@index == @total - 1}
            class="rounded p-1 text-zinc-500 hover:text-zinc-200 disabled:opacity-30"
            title="Move down"
            aria-label="Move down"
          >
            <.icon name="hero-arrow-down" class="h-3.5 w-3.5" />
          </button>
          <button
            type="button"
            phx-click="remove_step"
            phx-value-index={@index}
            data-confirm="Remove this step?"
            class="rounded p-1 text-zinc-500 hover:text-rose-300"
            title="Remove step"
            aria-label="Remove step"
          >
            <.icon name="hero-trash" class="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      <form phx-change="step_change" class="mt-3 space-y-3">
        <input type="hidden" name="index" value={@index} />

        <%!-- Action is the primary question the operator is answering
             ("what does this step DO"). Putting it first lets Step ID
             auto-derive from the chosen action below, instead of asking
             the operator to invent a name before they know what they
             named. --%>
        <div>
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Action
          </label>
          <input
            type="text"
            name="action_id"
            value={@step["action_id"]}
            list="catalog-actions"
            placeholder="linux.uptime"
            class={[input_class(), "font-mono text-xs"]}
          />
        </div>

        <div>
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Step ID
            <span class="ml-1 text-[9px] font-normal normal-case tracking-normal text-zinc-600">
              — referenced by other steps; auto-derived from Action
            </span>
          </label>
          <input
            type="text"
            name="step_id"
            value={@step["id"]}
            placeholder="step1"
            class={[input_class(), "font-mono text-xs"]}
          />
        </div>

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
          <div class="sm:col-span-1">
            <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
              Runner by
            </label>
            <select name="selector_kind" class={input_class()}>
              <option value="group" selected={@step["selector_kind"] == "group"}>
                group
              </option>
              <option value="runner_id" selected={@step["selector_kind"] == "runner_id"}>
                runner id
              </option>
            </select>
          </div>
          <div class="sm:col-span-2">
            <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
              Value
            </label>
            <input
              type="text"
              name="selector_value"
              value={@step["selector_value"]}
              placeholder={
                if(@step["selector_kind"] == "runner_id",
                  do: "runner UUID",
                  else: "e.g. cassandra-us-east1"
                )
              }
              class={input_class()}
            />
          </div>
        </div>
      </form>

      <%!-- Args live in a SIBLING form, not a nested one. Browsers
           auto-close the outer <form> on encountering a nested
           <form>, which would shred the layout for everything after
           the first inner form. Keeping it sibling means each arg
           row's phx-change "arg_change" routes correctly without
           collateral on the step form. --%>
      <.arg_editor
        index={@index}
        args={@step["args"] || []}
        action_id={@step["action_id"]}
        known_args={Map.get(@args_by_action, @step["action_id"], [])}
      />
    </div>
    """
  end

  attr :index, :integer, required: true
  attr :args, :list, required: true
  attr :action_id, :string, default: nil
  attr :known_args, :list, default: []

  defp arg_editor(assigns) do
    ~H"""
    <div class="mt-3">
      <div class="flex items-center justify-between">
        <div>
          <label class="block text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
            Args
          </label>
          <p :if={@known_args != []} class="mt-0.5 text-[10px] text-zinc-500">
            Known for <code class="font-mono text-zinc-400">{@action_id}</code>:
            <%= for {n, i} <- Enum.with_index(@known_args) do %>
              <span :if={i > 0}>, </span><code class="font-mono text-zinc-300">{n}</code>
            <% end %>
          </p>
        </div>
        <button
          type="button"
          phx-click="add_arg"
          phx-value-index={@index}
          class="text-[11px] font-medium text-indigo-300 hover:text-indigo-200"
        >
          + Add
        </button>
      </div>
      <p :if={@args == []} class="mt-1 text-[11px] text-zinc-500">
        No args.
      </p>
      <div :if={@args != []} class="mt-2 space-y-1.5">
        <%= for {arg, j} <- Enum.with_index(@args) do %>
          <form phx-change="arg_change" class="grid grid-cols-[1fr_1fr_auto] items-center gap-1.5">
            <input type="hidden" name="index" value={@index} />
            <input type="hidden" name="arg" value={j} />
            <input
              type="text"
              name="key"
              value={arg["key"]}
              placeholder="key"
              list={"args-#{datalist_id(@action_id)}"}
              class={[input_class(), "min-w-0 font-mono text-xs"]}
            />
            <input
              type="text"
              name="value"
              value={arg["value"]}
              placeholder="value"
              class={[input_class(), "min-w-0 text-xs"]}
            />
            <button
              type="button"
              phx-click="remove_arg"
              phx-value-index={@index}
              phx-value-arg={j}
              class="grid h-9 w-9 place-items-center rounded-lg border border-zinc-800 text-zinc-500 hover:border-rose-700 hover:text-rose-300"
              title="Remove arg"
              aria-label="Remove arg"
            >
              <.icon name="hero-trash" class="h-3.5 w-3.5" />
            </button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  defp input_class do
    "mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
  end

  # `<datalist id="...">` ids should be safe for HTML attributes. Action
  # ids like `cassandra.nodetool_status` have dots; some browsers tolerate
  # them in `list=` but it's brittle. Replace anything non-alphanumeric.
  defp datalist_id(nil), do: "none"

  defp datalist_id(action_id) when is_binary(action_id) do
    String.replace(action_id, ~r/[^a-zA-Z0-9_-]/, "_")
  end
end

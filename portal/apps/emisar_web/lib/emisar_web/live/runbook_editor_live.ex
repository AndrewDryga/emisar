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
  alias Emisar.{Catalog, Runbooks, Runners}
  alias EmisarWeb.Permissions
  alias Phoenix.LiveView.JS

  def mount(params, _session, socket) do
    # The editor is a manage surface — rendering a live form to a role whose
    # Save can only deny would trade twenty minutes of edits for a flash.
    if Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject) do
      {:ok, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:ok,
       socket
       |> put_flash(:info, "Runbooks are edited by owners and admins.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    end
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New runbook")
    |> assign(:runbook, nil)
    |> assign(:title, "")
    |> assign(:slug, "")
    |> assign(:description, "")
    |> assign(:steps, [example_action_step()])
    |> assign(:dirty?, false)
    |> assign_form(Runbooks.change_runbook())
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
        |> assign(:dirty?, false)
        |> assign_form(
          Runbooks.change_runbook(%{
            "title" => runbook.title,
            "slug" => runbook.slug,
            "description" => runbook.description
          })
        )
        |> assign_catalog()

      {:error, _} ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")
    end
  end

  # The catalog/runner reads are the heavy part of this mount — the
  # action list is the COMPLETE per-account catalog (hundreds of rows),
  # plus a runner list and group summaries. `mount` runs twice (dead
  # render + connected mount), so gate the reads behind `connected?/1`
  # (IL-18): the dead pass renders the editor with empty autocomplete
  # datalists, the connected pass populates them.
  defp assign_catalog(socket) do
    if connected?(socket) do
      load_catalog(socket)
    else
      socket
      |> assign(:catalog_actions, [])
      |> assign(:args_by_action, %{})
      |> assign(:risk_by_action, %{})
      |> assign(:runners, [])
      |> assign(:groups, [])
    end
  end

  defp load_catalog(socket) do
    # The step picker needs every advertised action selectable, not a
    # paginated page — a catalog with >35 actions must not silently hide
    # the rest. (Same complete-set read MCP uses; the UI list pages stay
    # paginated.)
    {:ok, runner_actions} = Catalog.list_all_actions_for_account(socket.assigns.current_subject)

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

    # action_id → risk (most-severe across runners), so each step card
    # shows the worst tier it composes — not whichever runner phoned home
    # last, which could under-state risk on a mixed-version fleet.
    risk_by_action = Catalog.most_severe_risk_by_action(runner_actions)

    # Options for the runner-target picker. Fail soft to empty lists if the
    # subject can't view runners — they can still author by typing, and the
    # picker just shows its "none yet" hint.
    runners =
      case Runners.list_all_runners_for_account(socket.assigns.current_subject) do
        {:ok, rs} -> rs
        _ -> []
      end

    groups =
      case Runners.list_group_summaries(socket.assigns.current_subject) do
        {:ok, rows} -> rows |> Enum.map(&elem(&1, 0)) |> Enum.reject(&is_nil/1) |> Enum.sort()
        _ -> []
      end

    socket
    |> assign(:catalog_actions, actions)
    |> assign(:args_by_action, args_by_action)
    |> assign(:risk_by_action, risk_by_action)
    |> assign(:runners, runners)
    |> assign(:groups, groups)
  end

  # -- Events ---------------------------------------------------------

  def handle_event("meta_change", params, socket) do
    title = params["title"] || socket.assigns.title
    slug = params["slug"] || socket.assigns.slug
    description = params["description"] || socket.assigns.description

    changeset =
      Runbooks.change_runbook(%{"title" => title, "slug" => slug, "description" => description})
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:title, title)
     |> assign(:slug, slug)
     |> assign(:description, description)
     |> assign_form(changeset)
     |> mark_dirty()}
  end

  def handle_event("step_change", %{"index" => idx} = params, socket) do
    i = safe_index(idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        kind = params["selector_kind"] || step["selector_kind"]

        # Switching the kind (group ↔ runner) swaps the option set, so values
        # selected against the old set no longer apply — drop them. An empty
        # <select multiple> posts no key at all, so default to [].
        values =
          if kind == step["selector_kind"], do: List.wrap(params["selector_values"]), else: []

        step
        # Form input is named `step_id` to avoid colliding with the form
        # element's HTML id — remap to the canonical "id" key here.
        |> Map.put("id", params["step_id"] || step["id"])
        |> Map.put("action_id", params["action_id"] || step["action_id"])
        |> Map.put("selector_kind", kind)
        |> Map.put("selector_values", values)
        |> maybe_autoderive_step_id(step)
      end)

    {:noreply, socket |> assign(:steps, steps) |> mark_dirty()}
  end

  def handle_event("add_action_step", _params, socket) do
    {:noreply,
     socket |> assign(:steps, socket.assigns.steps ++ [example_action_step()]) |> mark_dirty()}
  end

  def handle_event("remove_step", %{"index" => idx}, socket) do
    i = safe_index(idx)
    {:noreply, socket |> assign(:steps, List.delete_at(socket.assigns.steps, i)) |> mark_dirty()}
  end

  def handle_event("move_step", %{"index" => idx, "dir" => dir}, socket) do
    i = safe_index(idx)
    target = if dir == "up", do: i - 1, else: i + 1
    steps = socket.assigns.steps

    if target < 0 or target >= length(steps) do
      {:noreply, socket}
    else
      step = Enum.at(steps, i)
      steps = steps |> List.delete_at(i) |> List.insert_at(target, step)
      {:noreply, socket |> assign(:steps, steps) |> mark_dirty()}
    end
  end

  def handle_event("add_arg", %{"index" => idx}, socket) do
    i = safe_index(idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        Map.put(step, "args", args ++ [%{"key" => "", "value" => ""}])
      end)

    {:noreply, socket |> assign(:steps, steps) |> mark_dirty()}
  end

  def handle_event("remove_arg", %{"index" => idx, "arg" => arg_idx}, socket) do
    i = safe_index(idx)
    a = safe_index(arg_idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        Map.put(step, "args", List.delete_at(args, a))
      end)

    {:noreply, socket |> assign(:steps, steps) |> mark_dirty()}
  end

  def handle_event("arg_change", %{"index" => idx, "arg" => arg_idx} = params, socket) do
    i = safe_index(idx)
    a = safe_index(arg_idx)

    steps =
      List.update_at(socket.assigns.steps, i, fn step ->
        args = step["args"] || []
        updated = List.update_at(args, a, &Map.merge(&1, Map.take(params, ~w(key value))))
        Map.put(step, "args", updated)
      end)

    {:noreply, socket |> assign(:steps, steps) |> mark_dirty()}
  end

  def handle_event("save", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &save(&1, publish?: false)
    )
  end

  def handle_event("publish", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &save(&1, publish?: true)
    )
  end

  def handle_event("delete", _params, socket) do
    Permissions.gated(
      socket,
      Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject),
      &do_delete/1
    )
  end

  # phx-value step/arg indices are server-rendered, so they're valid in normal
  # use — but a crafted event with a non-numeric index would otherwise crash
  # this LV. Parse defensively, mapping bad input to an out-of-range index so
  # the List operations in the handlers above no-op rather than raise.
  defp safe_index(idx) do
    case Integer.parse(to_string(idx)) do
      {i, ""} when i >= 0 -> i
      _ -> 1_000_000_000
    end
  end

  # No runbook to delete on the /new page — a crafted "delete" event no-ops
  # rather than crashing the `%Runbook{}`-typed context call.
  defp do_delete(%{assigns: %{runbook: nil}} = socket), do: {:noreply, socket}

  defp do_delete(socket) do
    case Runbooks.delete_runbook(socket.assigns.runbook, socket.assigns.current_subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Runbook deleted.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't delete this runbook.")}
    end
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
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    else
      # Field errors (blank title, bad slug) render inline under their inputs;
      # a structural `definition` error has no input to bind to, so it surfaces
      # as a concise message above the Steps list (see render/1).
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}
    end
  end

  defp persist(%{assigns: %{runbook: nil}} = socket, attrs),
    do: Runbooks.create_runbook(attrs, socket.assigns.current_subject)

  defp persist(%{assigns: %{runbook: %Runbooks.Runbook{} = runbook}} = socket, attrs),
    do: Runbooks.save_new_version(runbook, attrs, socket.assigns.current_subject)

  defp maybe_publish(%Runbooks.Runbook{} = runbook, true, socket),
    do: Runbooks.publish(runbook, socket.assigns.current_subject)

  defp maybe_publish(%Runbooks.Runbook{} = runbook, false, _socket), do: {:ok, runbook}

  defp success_message(_, true), do: "Runbook published."
  defp success_message(%{version: v}, false) when v > 1, do: "Draft v#{v} saved."
  defp success_message(_, false), do: "Draft saved."

  # Draft-state marker: any editor mutation sets it; Cancel's discard
  # guard reads it, so an untouched editor leaves without friction.
  defp mark_dirty(socket), do: assign(socket, :dirty?, true)

  defp derive_slug(slug, title) do
    case String.trim(slug || "") do
      "" -> Emisar.Slug.slugify(title, max_length: 79)
      s -> s
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "runbook"))
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

  defp placeholder_step_id?(""), do: true
  defp placeholder_step_id?(id), do: Regex.match?(~r/^step\d+$/, id)

  # A runbook can publish only once it can actually run — at least one step, and
  # every step carrying both an action and a target. Drives which footer action
  # leads (Save draft until then), mirroring the per-step "No target set" hint.
  defp publishable?(steps), do: steps != [] and Enum.all?(steps, &step_runnable?/1)

  defp step_runnable?(step),
    do: (step["action_id"] || "") != "" and (step["selector_values"] || []) != []

  defp slug_from_action(action_id) do
    action_id
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 40)
  end

  # -- Step shape conversions ----------------------------------------

  defp example_action_step,
    do: %{
      "id" => "",
      "type" => "action",
      "action_id" => "",
      "selector_kind" => "group",
      "selector_values" => [],
      "args" => []
    }

  # JSON → editor state
  defp from_raw_step(raw) when is_map(raw) do
    {kind, values} = Runbooks.StepSelector.parse(raw["runner_selector"])

    %{
      "id" => raw["id"] || "step",
      "type" => "action",
      "action_id" => raw["action_id"] || "",
      # Default a targetless step to the "group" picker (matches
      # example_action_step) — parse returns a nil kind when no selector.
      "selector_kind" => kind || "group",
      "selector_values" => values,
      "args" => args_to_pairs(raw["args"] || %{})
    }
  end

  defp args_to_pairs(%{} = m) do
    Enum.map(m, fn {k, v} -> %{"key" => k, "value" => to_string(v)} end)
  end

  # Editor state → JSON
  defp to_raw_step(%{"type" => "action"} = step) do
    %{
      "id" => step["id"],
      "action_id" => step["action_id"],
      "runner_selector" => %{step["selector_kind"] => step["selector_values"] || []},
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

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
      width={:table}
    >
      <:title>
        <.detail_header back="Runbooks" navigate={~p"/app/#{@current_account}/runbooks"}>
          <%= if @runbook do %>
            Edit runbook <span class="font-mono text-base text-zinc-400">{@runbook.slug}</span>
            <span class="ml-2 text-sm font-normal text-zinc-400">v{@runbook.version}</span>
          <% else %>
            New runbook
          <% end %>
        </.detail_header>
      </:title>
      <:actions>
        <%!-- Editor archetype: no silent data loss on navigate — a dirty
             draft confirms the discard; an untouched editor leaves freely. --%>
        <.button
          variant={:secondary}
          size={:md}
          navigate={~p"/app/#{@current_account}/runbooks"}
          data-confirm={if @dirty?, do: "Discard unsaved changes?"}
        >
          Cancel
        </.button>
      </:actions>

      <div class="mt-4">
        <div class="grid grid-cols-1 gap-x-12 gap-y-12 lg:grid-cols-[minmax(0,1fr)_340px]">
          <section>
            <%!-- ONE add affordance: the dashed composer row below the list
               (where the next step lands) — a twin title-row button
               double-stated the action. --%>
            <.section_header title="Steps" />

            <%!-- A structural save error (e.g. a blank/invalid `definition`)
               has no metadata input to bind to, so it surfaces here above
               the steps rather than in a top flash banner. --%>
            <.event_block
              :if={msg = save_error_message(@form)}
              icon="hero-exclamation-triangle"
              tone={:rose}
              title={msg}
              class="mb-8"
            >
              <:body>Fix the steps below, then save again.</:body>
            </.event_block>

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

            <%!-- Each step is a dashed-bordered section — the frame groups a
               step's controls (action, targets, args) into one unit so a long
               runbook parses at a glance. Dashed, not a wash box (§8.1): an
               outline groups without filling. The datalists stay OUTSIDE this
               stack so they don't pick up the box chrome. --%>
            <div class="space-y-4">
              <div
                :for={{step, idx} <- Enum.with_index(@steps)}
                class="rounded-xl border border-dashed border-zinc-800 p-5"
              >
                <.step_unit
                  step={step}
                  index={idx}
                  total={length(@steps)}
                  args_by_action={@args_by_action}
                  risk={@risk_by_action[step["action_id"]]}
                  catalog_actions={@catalog_actions}
                  groups={@groups}
                  runners={@runners}
                />
              </div>
            </div>

            <%!-- Composer standard: the add affordance lives where the next
               step goes, so a 3-card list doesn't scroll back to the
               header's button. With zero steps it IS the empty state — a
               "no steps yet" hint above it would double the dashed chrome. --%>
            <div class="mt-8">
              <.add_row label="Add step" phx-click="add_action_step" />
            </div>
          </section>

          <%!-- Details first on phones: naming the runbook is the first thing
             a new one asks for, and the rail is three compact fields — the
             step list below it can run long. --%>
          <aside class="order-first space-y-8 lg:order-none">
            <section>
              <.section_header title="Details" />
              <form
                phx-change="meta_change"
                class="space-y-4 rounded-xl border border-dashed border-zinc-800 p-5"
              >
                <%!-- Flat `name=` (not the form's `runbook[title]`) — the metadata
                   form posts top-level keys that `meta_change` reads directly;
                   the `field=` only supplies the value + the post-validate error
                   display, which `<.input>` gates via `used_input?`. --%>
                <.input
                  field={@form[:title]}
                  name="title"
                  id="runbook_title"
                  label="Title"
                  label_variant={:eyebrow}
                  size={:compact}
                  required
                  placeholder="e.g. Cassandra: rolling repair"
                />
                <.input
                  field={@form[:slug]}
                  name="slug"
                  id="runbook_slug"
                  label="Slug"
                  label_variant={:eyebrow}
                  size={:compact}
                  class="font-mono text-xs"
                  placeholder="auto from title"
                />
                <.input
                  field={@form[:description]}
                  type="textarea"
                  name="description"
                  id="runbook_description"
                  label="Description"
                  label_variant={:eyebrow}
                  size={:compact}
                  rows="4"
                  placeholder="Optional human-readable summary."
                />
              </form>
            </section>

            <section :if={@runbook}>
              <.section_header title="Version" />
              <div class="rounded-xl border border-dashed border-zinc-800 p-5">
                <dl class="space-y-2 text-xs text-zinc-400">
                  <.kv label="Current">v{@runbook.version}</.kv>
                  <.kv label="Status"><.status_badge status={@runbook.status} /></.kv>
                  <.kv label="Saving creates">v{@runbook.version + 1}</.kv>
                </dl>
                <p
                  :if={@runbook.status == :published}
                  class="mt-4 text-xs text-zinc-400 leading-relaxed"
                >
                  Published runbooks are immutable — saving creates a new draft version.
                </p>
              </div>
            </section>
          </aside>
        </div>

        <%!-- Page-level footer: Save/Publish govern the WHOLE runbook (the
             Title lives in the right column), so they sit below the grid —
             inside the Steps panel, mobile stacking rendered Publish above
             the very field it validates. --%>
        <% ready_to_publish = publishable?(@steps) %>
        <%!-- Save draft leads until every step can actually run (has an action AND
             a target) — publishing an unrunnable runbook is a footgun on a
             brand-new one. The PRIMARY always holds the first slot, so the
             hierarchy reads the same in both states. --%>
        <div class="mt-10 flex items-center gap-3">
          <%= if ready_to_publish do %>
            <.button type="button" phx-click="publish" phx-disable-with="Publishing...">
              Publish
            </.button>
            <.button
              variant={:secondary}
              type="button"
              phx-click="save"
              phx-disable-with="Saving..."
            >
              Save draft
            </.button>
          <% else %>
            <.button type="button" phx-click="save" phx-disable-with="Saving...">
              Save draft
            </.button>
            <.button
              variant={:secondary}
              type="button"
              phx-click="publish"
              phx-disable-with="Publishing..."
            >
              Publish
            </.button>
          <% end %>

          <%!-- Destructive, so it sits apart from the save actions (ml-auto) and
               stays low-key (ghost/rose). Soft-delete of the whole slug family;
               only for an existing runbook. --%>
          <.confirm_button
            :if={@runbook}
            id="delete-runbook"
            class="ml-auto"
            title="Delete this runbook?"
            confirm_label="Delete runbook"
            icon="hero-trash"
            variant={:ghost}
            tone={:rose}
            on_confirm={JS.push("delete")}
          >
            <:body>
              Removes this runbook and all its versions. Runs already dispatched from it keep
              their own audit trail.
            </:body>
            Delete runbook
          </.confirm_button>
        </div>
      </div>
    </.dashboard_shell>
    """
  end

  attr :step, :map, required: true
  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :args_by_action, :map, required: true
  attr :risk, :any, default: nil
  attr :catalog_actions, :list, required: true
  attr :groups, :list, required: true
  attr :runners, :list, required: true

  defp step_unit(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
        Step {@index + 1}
      </span>
      <div class="flex items-center gap-1">
        <.icon_button
          icon="hero-arrow-up"
          label="Move up"
          phx-click="move_step"
          phx-value-index={@index}
          phx-value-dir="up"
          disabled={@index == 0}
        />
        <.icon_button
          icon="hero-arrow-down"
          label="Move down"
          phx-click="move_step"
          phx-value-index={@index}
          phx-value-dir="down"
          disabled={@index == @total - 1}
        />
        <.confirm_button
          id={"remove-step-#{@index}"}
          title="Remove this step?"
          confirm_label="Remove step"
          icon="hero-trash"
          variant={:ghost}
          size={:sm}
          tone={:rose}
          on_confirm={JS.push("remove_step", value: %{index: @index})}
        >
          <:body>It's dropped from the runbook; save to keep the change.</:body>
          Remove step
        </.confirm_button>
      </div>
    </div>

    <form phx-change="step_change" class="mt-3 space-y-3">
      <input type="hidden" name="index" value={@index} />

      <%!-- Action is the primary question the operator is answering
             ("what does this step DO"). Putting it first lets Step ID
             auto-derive from the chosen action below, instead of asking
             the operator to invent a name before they know what they
             named. --%>
      <div class="grid grid-cols-1 gap-2 sm:grid-cols-[2fr_1fr]">
        <div>
          <%!-- Every label row in the step grid is the same h-6 flex so the
               boxes below start in register — the risk pill otherwise inflates
               only this row and knocks the columns out of line. --%>
          <div class="flex h-6 items-center justify-between gap-2">
            <.label variant={:eyebrow}>
              Action
            </.label>
            <.risk_pill :if={@risk} risk={@risk} class="flex-none" />
          </div>
          <.input
            name="action_id"
            value={@step["action_id"]}
            list="catalog-actions"
            placeholder="linux.uptime"
            size={:compact}
            class="font-mono text-xs"
          />
          <%!-- A typo'd/unknown action previously failed SILENTLY (the risk
                 pill just never appeared) until dispatch refused the runbook. --%>
          <p
            :if={
              @step["action_id"] not in [nil, ""] and
                @step["action_id"] not in @catalog_actions
            }
            class="mt-1 text-[11px] text-amber-400/80"
          >
            Not in your catalog — no runner advertises this action.
          </p>
        </div>

        <div>
          <div class="flex h-6 items-center">
            <.label
              variant={:eyebrow}
              for={"step-#{@index}-id"}
              title="Referenced by other steps; auto-derives from Action"
            >
              Step ID
            </.label>
          </div>
          <.input
            id={"step-#{@index}-id"}
            name="step_id"
            value={@step["id"]}
            placeholder="auto from action"
            size={:compact}
            class="font-mono text-xs"
          />
        </div>
      </div>

      <div class="grid grid-cols-1 gap-2 sm:grid-cols-3">
        <div class="sm:col-span-1">
          <div class="flex h-6 items-center">
            <.label variant={:eyebrow} for={"step-#{@index}-selector-kind"}>
              Run on
            </.label>
          </div>
          <%!-- text-xs matches the sibling text inputs — the select otherwise
               keeps the compact size's text-sm and renders a taller box. --%>
          <.input
            id={"step-#{@index}-selector-kind"}
            name="selector_kind"
            type="select"
            size={:compact}
            class="text-xs"
            value={@step["selector_kind"]}
            options={[{"group", "group"}, {"runner", "runner_id"}]}
          />
        </div>
        <div class="sm:col-span-2">
          <div class="flex h-6 items-center">
            <.label variant={:eyebrow} for={"step-#{@index}-selector-values"}>
              Targets
            </.label>
          </div>
          <% selected = @step["selector_values"] || [] %>
          <% options =
            selector_options(@step["selector_kind"], @groups, @runners, selected)
            |> Enum.map(fn {label, value} ->
              %{value: value, label: label, disabled: false, selected: value in selected}
            end) %>
          <%!-- mt-1 matches the gap every compact input carries under its label. --%>
          <.checkbox_list
            id={"step-#{@index}-selector-values"}
            name="selector_values[]"
            options={options}
            class="mt-1"
          />
          <p :if={options == []} class="mt-1 text-[11px] text-zinc-400">
            {if @step["selector_kind"] == "runner_id",
              do: "No runners connected yet.",
              else: "No runner groups yet."}
          </p>
          <%!-- Mirror the run view's "no target set": a step with nothing
                 selected won't dispatch — flag it inline now, not only when
                 publish/dispatch refuses the whole runbook. (Hidden when there's
                 nothing to pick — the message above already explains that.) --%>
          <p
            :if={options != [] and (@step["selector_values"] || []) == []}
            class="mt-1 text-[11px] text-amber-400/80"
          >
            No target set — this step won't run until you pick one.
          </p>
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
          <.label variant={:eyebrow}>
            Args
          </.label>
          <p :if={@known_args != []} class="mt-0.5 text-[10px] text-zinc-400">
            Known for <code class="font-mono text-zinc-400">{@action_id}</code>:
            <%= for {n, i} <- Enum.with_index(@known_args) do %>
              <span :if={i > 0}>, </span><code class="font-mono text-zinc-300">{n}</code>
            <% end %>
          </p>
        </div>
        <.button
          type="button"
          variant={:secondary}
          size={:sm}
          icon="hero-plus"
          phx-click="add_arg"
          phx-value-index={@index}
        >
          Add
        </.button>
      </div>
      <%!-- A key + short value pair doesn't need the step's full width — cap it
           at half so the row reads as a compact field, not a stretched bar. --%>
      <div :if={@args != []} class="mt-2 space-y-1.5 sm:w-1/2">
        <%= for {arg, j} <- Enum.with_index(@args) do %>
          <%!-- items-end (not center): the compact inputs carry a mt-1 that sits
               them at the BOTTOM of their cell, so bottom-aligning the h-7 remove
               button lines it up with the input boxes exactly. --%>
          <form phx-change="arg_change" class="grid grid-cols-[1fr_1fr_auto] items-end gap-1.5">
            <input type="hidden" name="index" value={@index} />
            <input type="hidden" name="arg" value={j} />
            <%!-- min-w-0 rides the grid-item wrapper (not <.input>'s inner
                 input) so a long value can't blow the two 1fr columns out. --%>
            <div class="min-w-0">
              <.input
                name="key"
                value={arg["key"]}
                placeholder="key"
                list={"args-#{datalist_id(@action_id)}"}
                size={:compact}
                class="font-mono text-xs"
              />
            </div>
            <div class="min-w-0">
              <.input
                name="value"
                value={arg["value"]}
                placeholder="value"
                size={:compact}
                class="text-xs"
              />
            </div>
            <%!-- The key/value inputs are text-xs — a 28px box (h-7). Pin the
                 button to that exact height so it lines up in the items-center
                 row; an icon-only button's natural height came out a couple px
                 off and read as misaligned. --%>
            <.button
              type="button"
              variant={:secondary}
              tone={:rose}
              size={:sm}
              icon="hero-trash"
              phx-click="remove_arg"
              phx-value-index={@index}
              phx-value-arg={j}
              class="h-7"
            >
              <span class="sr-only">Remove arg</span>
            </.button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  # A `definition` error comes from the structured step builder, not a metadata
  # input — surface it as one concise line above the steps. nil → nothing to
  # show (no save attempted, or only field errors that already render inline,
  # which `<.input>` paints under their own inputs once the changeset has an
  # `:action`). The metadata text fields now route through `<.input>`, so this
  # is the only field error the editor renders by hand.
  defp save_error_message(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: nil}}), do: nil

  defp save_error_message(form) do
    errors = Enum.map(form[:definition].errors, &translate_error/1)

    case errors do
      # Sentence-case the changeset fragment — it renders as the error block's
      # title directly under the Steps header, so a "Steps:" prefix would stutter.
      [msg | _] -> String.capitalize(msg)
      [] -> nil
    end
  end

  # `<datalist id="...">` ids should be safe for HTML attributes. Action
  # ids like `cassandra.nodetool_status` have dots; some browsers tolerate
  # them in `list=` but it's brittle. Replace anything non-alphanumeric.
  defp datalist_id(nil), do: "none"

  defp datalist_id(action_id) when is_binary(action_id) do
    String.replace(action_id, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  # Options ({label, value}) for the runner-target multi-select. Always
  # includes any currently selected value that isn't in the live set (a group
  # whose runners all disconnected, say) so an existing selection is never
  # silently dropped on the next save.
  defp selector_options("runner_id", _groups, runners, selected) do
    known = Enum.map(runners, &{runner_label(&1), &1.id})
    known_ids = Enum.map(runners, & &1.id)
    known ++ for(v <- selected, v not in known_ids, do: {v, v})
  end

  defp selector_options(_group, groups, _runners, selected) do
    (groups ++ selected) |> Enum.uniq() |> Enum.map(&{&1, &1})
  end

  defp runner_label(r) do
    base = r.name || r.external_id || r.id
    if r.group, do: "#{base} · #{r.group}", else: base
  end
end

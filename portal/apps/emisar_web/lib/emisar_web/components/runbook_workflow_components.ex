defmodule EmisarWeb.RunbookWorkflowComponents do
  @moduledoc false

  use EmisarWeb, :html
  alias EmisarWeb.RunbookEditorCatalog

  @doc "Returns the human runner name from a frozen runner reference."
  def runner_name(ref) when is_binary(ref) do
    ref
    |> String.split("~", parts: 2)
    |> List.first()
  end

  def runner_name(_ref), do: "Unknown runner"

  attr :arguments, :map, required: true
  attr :class, :string, default: nil
  attr :show_empty?, :boolean, default: false

  @doc "Renders visible frozen arguments as a compact decision-ready list."
  def argument_list(assigns) do
    assigns = assign(assigns, :rows, Enum.sort_by(assigns.arguments, &elem(&1, 0)))

    ~H"""
    <div :if={@rows != [] or @show_empty?} class={@class}>
      <p class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
        Arguments
      </p>
      <p :if={@rows == []} class="mt-1 text-xs text-zinc-500">None</p>
      <dl :if={@rows != []} class="mt-1 divide-y divide-zinc-800/60">
        <div
          :for={{name, value} <- @rows}
          class="grid gap-1 py-1.5 text-xs sm:grid-cols-[8rem_minmax(0,1fr)] sm:gap-3"
        >
          <dt class="break-all font-mono text-zinc-400">{name}</dt>
          <dd class="min-w-0 break-words font-mono text-zinc-200">
            {argument_value(value)}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  defp argument_value(%{"from_output" => ref}), do: "From #{ref}"
  defp argument_value(value) when is_binary(value), do: value
  defp argument_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp argument_value(nil), do: "null"
  defp argument_value(value), do: Jason.encode!(value)

  defp available_output_refs(draft, stage_index) do
    draft["stages"]
    |> Enum.take(stage_index)
    |> Enum.flat_map(fn stage ->
      Enum.flat_map(stage["steps"], fn step ->
        Enum.map(step["outputs"], &"#{step["id"]}.#{&1["id"]}")
      end)
    end)
    |> Enum.reject(&String.ends_with?(&1, "."))
  end

  defp reference_options("input", draft, _stage_index),
    do: Enum.map(draft["inputs"], &{&1["id"], &1["id"]})

  defp reference_options("output", draft, stage_index),
    do: Enum.map(available_output_refs(draft, stage_index), &{&1, &1})

  defp reference_options(_source, _draft, _stage_index), do: []

  defp argument_summary(argument) do
    requirement = if argument["required"] == "true", do: "Required", else: "Optional"
    "#{requirement} #{argument_type_label(argument["type"])}"
  end

  defp argument_type_label("boolean"), do: "true or false value"
  defp argument_type_label("duration"), do: "duration"
  defp argument_type_label("integer"), do: "whole number"
  defp argument_type_label("integer_array"), do: "list of whole numbers"
  defp argument_type_label("json"), do: "JSON value"
  defp argument_type_label("number"), do: "number"
  defp argument_type_label("path"), do: "file path"
  defp argument_type_label("string"), do: "text value"
  defp argument_type_label("string_array"), do: "list of text values"
  defp argument_type_label(_type), do: "value"

  defp argument_source_options(%{"required" => "true", "sensitive" => "true"}),
    do: [{"Run-time input", "input"}, {"Prior output", "output"}]

  defp argument_source_options(%{"required" => "true"}),
    do: [{"Literal", "literal"}, {"Run-time input", "input"}, {"Prior output", "output"}]

  defp argument_source_options(%{"sensitive" => "true"}),
    do: [{"Omit", "omit"}, {"Run-time input", "input"}, {"Prior output", "output"}]

  defp argument_source_options(_argument),
    do: [
      {"Omit", "omit"},
      {"Literal", "literal"},
      {"Run-time input", "input"},
      {"Prior output", "output"}
    ]

  defp populated_step?(step) do
    String.trim(step["action"] || "") != "" or step["target_refs"] != [] or step["args"] != [] or
      step["outputs"] != [] or step["success"] != []
  end

  defp populated_stage?(stage), do: Enum.any?(stage["steps"], &populated_step?/1)

  attr :stage, :map, required: true
  attr :stage_index, :integer, required: true
  attr :total_stages, :integer, required: true
  attr :draft, :map, required: true
  attr :catalog, :map, required: true
  attr :open_panels, :any, required: true
  attr :read_only?, :boolean, required: true

  def stage_editor(assigns) do
    ~H"""
    <article
      id={"runbook-stage-#{@stage_index}"}
      class="rounded-2xl border border-zinc-800 p-5 sm:p-6"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
          Stage {@stage_index + 1}
        </span>
        <div class="flex items-center gap-1">
          <.icon_button
            icon="hero-arrow-up"
            label="Move stage up"
            phx-click="move_stage"
            phx-value-index={@stage_index}
            phx-value-direction="up"
            disabled={@read_only? or @stage_index == 0}
          />
          <.icon_button
            icon="hero-arrow-down"
            label="Move stage down"
            phx-click="move_stage"
            phx-value-index={@stage_index}
            phx-value-direction="down"
            disabled={@read_only? or @stage_index == @total_stages - 1}
          />
          <.icon_button
            icon="hero-trash"
            label="Remove stage"
            phx-click="remove_stage"
            phx-value-index={@stage_index}
            disabled={@read_only?}
            data-confirm={if populated_stage?(@stage), do: "Remove this populated stage?"}
          />
        </div>
      </div>

      <div
        id={"runbook-stage-#{@stage_index}-overview"}
        class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-[9rem_minmax(0,1fr)_10rem_11rem]"
      >
        <.input
          name={"draft[stages][#{@stage_index}][id]"}
          value={@stage["id"]}
          label="Identifier"
          label_variant={:eyebrow}
          disabled={@read_only?}
          class="font-mono"
        />
        <.input
          name={"draft[stages][#{@stage_index}][title]"}
          value={@stage["title"]}
          label="Title"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][mode]"}
          value={@stage["mode"]}
          label="Execution"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"Sequential", "sequential"}, {"Parallel", "parallel"}]}
        />
        <.input
          :if={@stage["mode"] == "parallel"}
          type="number"
          min="1"
          max="16"
          name={"draft[stages][#{@stage_index}][max_parallel]"}
          value={@stage["max_parallel"]}
          label="Maximum concurrency"
          label_variant={:eyebrow}
          disabled={@read_only?}
        />
      </div>

      <div class="mt-6 space-y-4">
        <.step_editor
          :for={{step, step_index} <- Enum.with_index(@stage["steps"])}
          step={step}
          step_index={step_index}
          total_steps={length(@stage["steps"])}
          stage_index={@stage_index}
          draft={@draft}
          catalog={@catalog}
          open_panels={@open_panels}
          read_only?={@read_only?}
        />
      </div>

      <.add_row
        label="Add step"
        class="mt-6"
        phx-click="add_step"
        phx-value-stage={@stage_index}
        disabled={@read_only?}
      />
    </article>
    """
  end

  attr :step, :map, required: true
  attr :step_index, :integer, required: true
  attr :total_steps, :integer, required: true
  attr :stage_index, :integer, required: true
  attr :draft, :map, required: true
  attr :catalog, :map, required: true
  attr :open_panels, :any, required: true
  attr :read_only?, :boolean, required: true

  defp step_editor(assigns) do
    choice = RunbookEditorCatalog.action_value(assigns.step["pack_id"], assigns.step["action"])

    assigns =
      assigns
      |> assign(:action_choice, choice)
      |> assign(
        :action_options,
        RunbookEditorCatalog.action_options(
          assigns.catalog,
          assigns.step["target_refs"],
          choice
        )
      )
      |> assign(
        :target_options,
        RunbookEditorCatalog.target_options(assigns.catalog, assigns.step["target_refs"])
      )
      |> assign(
        :action_available?,
        RunbookEditorCatalog.action_available?(
          assigns.catalog,
          assigns.step["target_refs"],
          choice
        )
      )
      |> assign(
        :risk,
        RunbookEditorCatalog.risk(
          assigns.catalog,
          assigns.step["pack_id"],
          assigns.step["action"]
        )
      )

    ~H"""
    <section
      id={"runbook-stage-#{@stage_index}-step-#{@step_index}"}
      class="rounded-xl border border-zinc-800 bg-zinc-950/40 p-5"
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
            Step {@step_index + 1}
          </span>
          <.risk_pill :if={@risk} risk={@risk} />
        </div>
        <div class="flex items-center gap-1">
          <.icon_button
            icon="hero-arrow-up"
            label="Move step up"
            phx-click="move_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            phx-value-direction="up"
            disabled={@read_only? or @step_index == 0}
          />
          <.icon_button
            icon="hero-arrow-down"
            label="Move step down"
            phx-click="move_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            phx-value-direction="down"
            disabled={@read_only? or @step_index == @total_steps - 1}
          />
          <.icon_button
            icon="hero-trash"
            label="Remove step"
            phx-click="remove_step"
            phx-value-stage={@stage_index}
            phx-value-step={@step_index}
            disabled={@read_only?}
            data-confirm={if populated_step?(@step), do: "Remove this populated step?"}
          />
        </div>
      </div>

      <div
        id={"runbook-stage-#{@stage_index}-step-#{@step_index}-overview"}
        class="mt-5 grid gap-4 xl:grid-cols-[9rem_minmax(0,1fr)_minmax(0,1fr)] xl:items-start"
      >
        <.input
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][id]"}
          value={@step["id"]}
          label="Identifier"
          label_variant={:eyebrow}
          disabled={@read_only?}
          class="font-mono"
        />

        <.target_picker
          step={@step}
          stage_index={@stage_index}
          step_index={@step_index}
          catalog={@catalog}
          options={@target_options}
          read_only?={@read_only?}
        />

        <div>
          <.label variant={:eyebrow}>Action</.label>
          <.select
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][action_choice]"}
            options={@action_options}
            prompt={if @step["target_refs"] == [], do: "Choose targets first", else: "Choose action…"}
            prompt_selected={@action_choice == ""}
            disabled={@read_only? or @step["target_refs"] == []}
            class="mt-2"
            aria-label="Action"
          />
          <p
            :if={@action_choice != "" and not @action_available?}
            class="mt-2 text-xs leading-relaxed text-rose-300"
          >
            This action is not available on every selected runner. Choose another action or update
            the targets.
          </p>
        </div>
      </div>

      <.bindings_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        draft={@draft}
        read_only?={@read_only?}
      />
      <.outputs_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        read_only?={@read_only?}
      />
      <.success_editor
        step={@step}
        stage_index={@stage_index}
        step_index={@step_index}
        read_only?={@read_only?}
      />
      <.retry_editor
        wait={@step["wait"]}
        stage_index={@stage_index}
        step_index={@step_index}
        open_panels={@open_panels}
        read_only?={@read_only?}
      />
    </section>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :catalog, :map, required: true
  attr :options, :list, required: true
  attr :read_only?, :boolean, required: true

  defp target_picker(assigns) do
    refs = assigns.step["target_refs"] || []
    unavailable = Enum.count(refs, &(not Map.has_key?(assigns.catalog.target_runner_ids, &1)))

    assigns =
      assigns
      |> assign(:refs, refs)
      |> assign(:unavailable, unavailable)
      |> assign(:label, target_selection_label(assigns.catalog, refs, unavailable))
      |> assign(
        :disabled?,
        assigns.read_only? or (refs == [] and assigns.catalog.target_options == [])
      )

    ~H"""
    <div id={"runbook-stage-#{@stage_index}-step-#{@step_index}-targets"}>
      <.label variant={:eyebrow}>Targets</.label>

      <div
        :if={@disabled?}
        id={"runbook-stage-#{@stage_index}-step-#{@step_index}-target-trigger"}
        aria-disabled="true"
        class={[
          "mt-2 flex min-h-10 w-full items-center justify-between gap-3 rounded-lg bg-zinc-900 px-3 py-2.5 text-sm ring-1 ring-inset",
          @unavailable == 0 && "text-zinc-500 ring-zinc-800",
          @unavailable > 0 && "text-rose-300 ring-rose-500/50"
        ]}
      >
        <span class="min-w-0 truncate">{@label}</span>
        <.icon name="hero-chevron-down-micro" class="h-5 w-5 shrink-0 text-zinc-500" />
      </div>

      <.dropdown
        :if={not @disabled?}
        id={"runbook-stage-#{@stage_index}-step-#{@step_index}-target-picker"}
        align={:left}
        panel_position={:flow_on_narrow}
        class="mt-2"
        summary_class={target_summary_class(@unavailable)}
        panel_class="z-40 mt-2 max-h-64 w-full min-w-[18rem] overflow-y-auto overscroll-contain p-1 text-sm"
      >
        <:trigger>
          <span
            id={"runbook-stage-#{@stage_index}-step-#{@step_index}-target-trigger"}
            class="flex min-w-0 flex-1 items-center justify-between gap-3"
          >
            <span class="min-w-0 truncate">{@label}</span>
            <.icon
              name="hero-chevron-down-micro"
              class="h-5 w-5 shrink-0 text-zinc-500 transition-transform group-open:rotate-180"
            />
          </span>
        </:trigger>

        <div id={"runbook-stage-#{@stage_index}-step-#{@step_index}-target-options"}>
          <.target_choice
            :for={option <- @options}
            option={option}
            stage_index={@stage_index}
            step_index={@step_index}
            at_limit?={length(@refs) >= 16}
          />
        </div>
      </.dropdown>
    </div>
    """
  end

  attr :option, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :at_limit?, :boolean, required: true

  defp target_choice(%{option: %{value: ""}} = assigns) do
    ~H"""
    <p class="px-3 py-2 text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
      {@option.label}
    </p>
    """
  end

  defp target_choice(assigns) do
    selected? = assigns.option.selected
    unavailable? = Map.get(assigns.option, :unavailable, false)
    disabled? = not selected? and (assigns.option.disabled or assigns.at_limit?)

    assigns =
      assigns
      |> assign(:selected?, selected?)
      |> assign(:unavailable?, unavailable?)
      |> assign(:disabled?, disabled?)
      |> assign(:event, if(selected?, do: "remove_target", else: "add_target"))

    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-stage={@stage_index}
      phx-value-step={@step_index}
      phx-value-target={@option.value}
      disabled={@disabled?}
      class={[
        "flex min-h-10 w-full items-center gap-2.5 rounded px-3 py-2 text-left transition-colors",
        @selected? && "bg-white/[0.05] text-zinc-100 hover:bg-white/[0.08]",
        not @selected? && not @disabled? && "text-zinc-300 hover:bg-zinc-800",
        @disabled? && "cursor-not-allowed text-zinc-500 opacity-50"
      ]}
    >
      <span class="flex h-4 w-4 shrink-0 items-center justify-center">
        <.icon :if={@selected?} name="hero-check-micro" class="h-4 w-4 text-zinc-300" />
      </span>
      <span class="min-w-0 flex-1 truncate">{@option.label}</span>
      <span :if={@unavailable?} class="shrink-0 text-[10px] font-medium text-rose-300">
        Unavailable
      </span>
    </button>
    """
  end

  defp target_selection_label(%{target_options: []}, [], _unavailable),
    do: "No online runners available"

  defp target_selection_label(_catalog, [], _unavailable), do: "Choose runners or groups…"

  defp target_selection_label(catalog, [ref], 0),
    do: RunbookEditorCatalog.target_label(catalog, ref)

  defp target_selection_label(catalog, [ref], _unavailable),
    do: "Unavailable · #{RunbookEditorCatalog.target_label(catalog, ref)}"

  defp target_selection_label(_catalog, refs, 0), do: "#{length(refs)} targets"

  defp target_selection_label(_catalog, refs, unavailable),
    do: "#{length(refs)} targets · #{unavailable} unavailable"

  defp target_summary_class(0) do
    "flex min-h-10 w-full items-center justify-between gap-3 rounded-lg bg-zinc-900 " <>
      "px-3 py-2.5 text-left text-sm text-zinc-100 ring-1 ring-inset ring-zinc-800 " <>
      "hover:ring-zinc-700 focus:ring-brand-500"
  end

  defp target_summary_class(_unavailable) do
    "flex min-h-10 w-full items-center justify-between gap-3 rounded-lg bg-zinc-900 " <>
      "px-3 py-2.5 text-left text-sm text-rose-300 ring-1 ring-inset ring-rose-500/50 " <>
      "focus:ring-rose-500"
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp bindings_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <p class="text-xs font-semibold text-zinc-200">Arguments</p>

      <p :if={@step["action"] == ""} class="mt-3 text-xs text-zinc-500">
        Choose an action to configure its arguments.
      </p>

      <p :if={@step["action"] != "" and @step["args"] == []} class="mt-3 text-xs text-zinc-500">
        This action has no arguments.
      </p>

      <div class="mt-3 space-y-3">
        <div
          :for={{argument, index} <- Enum.with_index(@step["args"])}
          class="rounded-xl bg-zinc-950/40 p-4 ring-1 ring-white/10"
        >
          <div>
            <h4 class="font-mono text-sm font-medium text-zinc-200">{argument["name"]}</h4>
            <p class="mt-1 text-xs text-zinc-500">{argument_summary(argument)}</p>
          </div>

          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][name]"}
            value={argument["name"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][type]"}
            value={argument["type"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][required]"}
            value={argument["required"]}
          />
          <input
            type="hidden"
            name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][sensitive]"}
            value={argument["sensitive"]}
          />

          <div class={[
            "mt-4 grid gap-3",
            if(argument["source"] == "omit",
              do: "max-w-48",
              else: "sm:grid-cols-[11rem_minmax(0,1fr)]"
            )
          ]}>
            <.input
              type="select"
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][args][#{index}][source]"}
              value={argument["source"]}
              label="Use"
              label_variant={:eyebrow}
              aria-label={"#{argument["name"]} binding source"}
              disabled={@read_only?}
              options={argument_source_options(argument)}
            />
            <.argument_value_input
              argument={argument}
              index={index}
              stage_index={@stage_index}
              step_index={@step_index}
              draft={@draft}
              read_only?={@read_only?}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :argument, :map, required: true
  attr :index, :integer, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp argument_value_input(assigns) do
    name =
      "draft[stages][#{assigns.stage_index}][steps][#{assigns.step_index}]" <>
        "[args][#{assigns.index}]"

    assigns = assign(assigns, :name, name)

    ~H"""
    <div class={@argument["source"] == "omit" && "hidden"}>
      <input
        :if={@argument["source"] != "literal"}
        type="hidden"
        name={"#{@name}[value]"}
        value={@argument["value"]}
      />
      <input
        :if={@argument["source"] in ["literal", "omit"]}
        type="hidden"
        name={"#{@name}[ref]"}
        value={@argument["ref"]}
      />

      <.input
        :if={@argument["source"] == "literal" and @argument["type"] == "boolean"}
        type="select"
        name={"#{@name}[value]"}
        value={@argument["value"]}
        label="Value"
        label_variant={:eyebrow}
        aria-label={"#{@argument["name"]} literal value"}
        disabled={@read_only?}
        prompt="Choose value"
        options={[{"False", "false"}, {"True", "true"}]}
      />
      <.input
        :if={@argument["source"] == "literal" and @argument["type"] in ["integer", "number"]}
        type="number"
        step={if @argument["type"] == "number", do: "any", else: "1"}
        name={"#{@name}[value]"}
        value={@argument["value"]}
        label="Value"
        label_variant={:eyebrow}
        aria-label={"#{@argument["name"]} literal value"}
        disabled={@read_only?}
        placeholder="Value"
      />
      <.input
        :if={
          @argument["source"] == "literal" and
            @argument["type"] not in ["boolean", "integer", "number"]
        }
        name={"#{@name}[value]"}
        value={@argument["value"]}
        label="Value"
        label_variant={:eyebrow}
        aria-label={"#{@argument["name"]} literal value"}
        placeholder={
          if @argument["type"] in ["string_array", "integer_array"],
            do: "JSON array",
            else: "Value"
        }
        disabled={@read_only?}
        class={if @argument["type"] in ["string_array", "integer_array"], do: "font-mono text-xs"}
      />
      <.input
        :if={@argument["source"] in ["input", "output"]}
        type="select"
        name={"#{@name}[ref]"}
        value={@argument["ref"]}
        label={if @argument["source"] == "input", do: "Run-time input", else: "Prior output"}
        label_variant={:eyebrow}
        aria-label={"#{@argument["name"]} reference"}
        disabled={@read_only?}
        options={reference_options(@argument["source"], @draft, @stage_index)}
        prompt="Choose value"
      />
    </div>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :read_only?, :boolean, required: true

  defp outputs_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div>
        <p class="text-xs font-semibold text-zinc-200">Extracted outputs</p>
        <p class="mt-0.5 text-[11px] text-zinc-400">
          Keep only the result fields later conditions or stages need.
        </p>
      </div>

      <p :if={@step["outputs"] == []} class="mt-3 text-xs text-zinc-500">
        No extracted outputs.
      </p>

      <div class="mt-3 space-y-3">
        <div
          :for={{output, index} <- Enum.with_index(@step["outputs"])}
          id={"runbook-stage-#{@stage_index}-step-#{@step_index}-output-#{index}"}
          class="rounded-lg border border-zinc-800/70 p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
              Output {index + 1}
            </span>
            <.icon_button
              icon="hero-trash"
              label="Remove output"
              phx-click="remove_output"
              phx-value-stage={@stage_index}
              phx-value-step={@step_index}
              phx-value-index={index}
              disabled={@read_only?}
            />
          </div>

          <div class="mt-4 space-y-4">
            <div
              id={"runbook-stage-#{@stage_index}-step-#{@step_index}-output-#{index}-identity"}
              class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_11rem]"
            >
              <.input
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][id]"}
                value={output["id"]}
                label="Output ID"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} ID"}
                placeholder="status"
                disabled={@read_only?}
                class="font-mono"
              />
              <.input
                type="select"
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][sensitive]"}
                value={output["sensitive"]}
                label="Visibility"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} sensitivity"}
                disabled={@read_only?}
                options={[{"Visible", "false"}, {"Sensitive", "true"}]}
              />
            </div>

            <div
              id={"runbook-stage-#{@stage_index}-step-#{@step_index}-output-#{index}-extractor"}
              class="grid gap-3 sm:grid-cols-2 lg:grid-cols-[12rem_12rem_minmax(0,1fr)]"
            >
              <.input
                type="select"
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][source]"}
                value={output["source"]}
                label="Read from"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} source"}
                disabled={@read_only?}
                options={[
                  {"Structured output", "structured_output"},
                  {"stdout", "stdout"},
                  {"stderr", "stderr"}
                ]}
              />
              <.input
                type="select"
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][extract_type]"}
                value={output["extract_type"]}
                label="Extract with"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} extractor"}
                disabled={@read_only?}
                options={[
                  {"JSON Pointer", "json_pointer"},
                  {"Contains", "contains"},
                  {"Grep", "grep"},
                  {"Regex", "regex"}
                ]}
              />
              <.input
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][expression]"}
                value={output["expression"]}
                label="Expression"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} expression"}
                placeholder={
                  if output["extract_type"] == "json_pointer", do: "/status", else: "pattern"
                }
                disabled={@read_only?}
                class="font-mono"
              />
            </div>

            <div :if={output["extract_type"] == "regex"} class="max-w-36">
              <.input
                name={"draft[stages][#{@stage_index}][steps][#{@step_index}][outputs][#{index}][capture]"}
                value={output["capture"]}
                label="Capture group"
                label_variant={:eyebrow}
                aria-label={"Output #{index + 1} regex capture"}
                placeholder="0"
                disabled={@read_only?}
                class="font-mono"
              />
            </div>
          </div>
        </div>
      </div>
      <.add_row
        label="Add output"
        class="mt-3"
        phx-click="add_output"
        phx-value-stage={@stage_index}
        phx-value-step={@step_index}
        disabled={@read_only?}
      />
    </div>
    """
  end

  attr :step, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :read_only?, :boolean, required: true

  defp success_editor(assigns) do
    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <div>
        <p class="text-xs font-semibold text-zinc-200">Success conditions</p>
        <p class="mt-0.5 text-[11px] text-zinc-400">
          Every condition must pass. Conditions can read only extracted outputs.
        </p>
      </div>

      <p :if={@step["outputs"] == []} class="mt-3 text-xs text-zinc-500">
        Add an extracted output before adding a success condition.
      </p>
      <p :if={@step["outputs"] != [] and @step["success"] == []} class="mt-3 text-xs text-zinc-500">
        No extra success conditions. A successful action exit is enough.
      </p>

      <div class="mt-3 space-y-3">
        <div
          :for={{condition, index} <- Enum.with_index(@step["success"])}
          id={"runbook-stage-#{@stage_index}-step-#{@step_index}-condition-#{index}"}
          class="rounded-lg border border-zinc-800/70 p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
              Condition {index + 1}
            </span>
            <.icon_button
              icon="hero-trash"
              label="Remove condition"
              phx-click="remove_success"
              phx-value-stage={@stage_index}
              phx-value-step={@step_index}
              phx-value-index={index}
              disabled={@read_only?}
            />
          </div>
          <div
            id={"runbook-stage-#{@stage_index}-step-#{@step_index}-condition-#{index}-controls"}
            class="mt-4 grid gap-3 lg:grid-cols-[minmax(0,1fr)_13rem_minmax(0,1.5fr)]"
          >
            <.input
              type="select"
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][output]"}
              value={condition["output"]}
              label="Output"
              label_variant={:eyebrow}
              aria-label={"Condition #{index + 1} output"}
              disabled={@read_only?}
              prompt="Choose output"
              options={Enum.map(@step["outputs"], &{&1["id"], &1["id"]})}
            />
            <.input
              type="select"
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][operator]"}
              value={condition["operator"]}
              label="Must be"
              label_variant={:eyebrow}
              aria-label={"Condition #{index + 1} operator"}
              disabled={@read_only?}
              options={[
                {"Equals", "equals"},
                {"Not equal", "not_equals"},
                {"Greater than", "greater_than"},
                {"Greater than or equal", "greater_than_or_equal"},
                {"Less than", "less_than"},
                {"Less than or equal", "less_than_or_equal"},
                {"Contains", "contains"},
                {"One of", "one_of"},
                {"Matches regex", "matches"}
              ]}
            />
            <.input
              name={"draft[stages][#{@stage_index}][steps][#{@step_index}][success][#{index}][value]"}
              value={condition["value"]}
              label="Expected JSON value"
              label_variant={:eyebrow}
              aria-label={"Condition #{index + 1} JSON value"}
              placeholder="Enter a JSON value"
              disabled={@read_only?}
              class="font-mono"
            />
          </div>
        </div>
      </div>
      <.add_row
        label="Add condition"
        class="mt-3"
        phx-click="add_success"
        phx-value-stage={@stage_index}
        phx-value-step={@step_index}
        disabled={@read_only? or @step["outputs"] == []}
      />
    </div>
    """
  end

  attr :wait, :map, required: true
  attr :stage_index, :integer, required: true
  attr :step_index, :integer, required: true
  attr :open_panels, :any, required: true
  attr :read_only?, :boolean, required: true

  defp retry_editor(assigns) do
    key = "retry-#{assigns.stage_index}-#{assigns.step_index}"
    assigns = assign(assigns, :panel_key, key)

    ~H"""
    <div class="mt-6 border-t border-zinc-800/70 pt-5">
      <.panel_toggle
        panel_key={@panel_key}
        open?={MapSet.member?(@open_panels, @panel_key)}
        label="Retry policy"
        hint={if @wait["enabled"] == "true", do: "Observe again", else: "No retry · halt on failure"}
      />
      <div
        :if={MapSet.member?(@open_panels, @panel_key)}
        id={"runbook-stage-#{@stage_index}-step-#{@step_index}-retry-controls"}
        class="mt-4 grid gap-3 lg:grid-cols-[minmax(16rem,2fr)_minmax(9rem,1fr)_minmax(9rem,1fr)_minmax(11rem,1fr)]"
      >
        <.input
          type="select"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][enabled]"}
          value={@wait["enabled"]}
          label="When conditions fail"
          label_variant={:eyebrow}
          disabled={@read_only?}
          options={[{"Halt execution", "false"}, {"Observe again", "true"}]}
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="5"
          max="3600"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][interval_seconds]"}
          value={@wait["interval_seconds"]}
          label="Interval (seconds)"
          label_variant={:eyebrow}
          disabled={@read_only?}
          class="tabular-nums"
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="5"
          max="86400"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][timeout_seconds]"}
          value={@wait["timeout_seconds"]}
          label="Timeout (seconds)"
          label_variant={:eyebrow}
          disabled={@read_only?}
          class="tabular-nums"
        />
        <.input
          :if={@wait["enabled"] == "true"}
          type="number"
          min="2"
          max="100"
          name={"draft[stages][#{@stage_index}][steps][#{@step_index}][wait][max_attempts]"}
          value={@wait["max_attempts"]}
          label="Maximum observations"
          label_variant={:eyebrow}
          disabled={@read_only?}
          class="tabular-nums"
        />
      </div>
    </div>
    """
  end

  attr :panel_key, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :open?, :boolean, required: true

  defp panel_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_panel"
      phx-value-key={@panel_key}
      aria-expanded={to_string(@open?)}
      class="inline-flex w-full items-center gap-1.5 text-left text-xs font-medium text-zinc-400 hover:text-zinc-200"
    >
      <.icon
        name="hero-chevron-right"
        class={
          "h-3.5 w-3.5 shrink-0 transition-transform motion-reduce:transition-none" <>
            if(@open?, do: " rotate-90", else: "")
        }
      />
      <span>{@label}</span>
      <span :if={@hint} class="ml-auto font-normal text-zinc-500">{@hint}</span>
    </button>
    """
  end
end

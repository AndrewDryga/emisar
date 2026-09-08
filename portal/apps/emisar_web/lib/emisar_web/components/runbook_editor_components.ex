defmodule EmisarWeb.RunbookEditorComponents do
  @moduledoc false

  use EmisarWeb, :html
  alias Emisar.Runbooks
  alias EmisarWeb.{RunbookDraft, RunbookMarkdown, RunbookWorkflowComponents}

  defp issue_target(path) when is_binary(path) do
    case Regex.run(~r{^/stages/(\d+)(?:/steps/(\d+))?}, path) do
      [_, stage, step] -> "runbook-stage-#{stage}-step-#{step}"
      [_, stage] -> "runbook-stage-#{stage}"
      _other -> "runbook-editor-form"
    end
  end

  defp issue_target(_path), do: "runbook-editor-form"

  defp issue_label(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["stages", stage, "steps", step | fields] ->
        "Stage #{index_label(stage)} · Step #{index_label(step)}#{field_suffix(fields)}"

      ["stages", stage | fields] ->
        "Stage #{index_label(stage)}#{field_suffix(fields)}"

      ["inputs", input | fields] ->
        "Input #{index_label(input)}#{field_suffix(fields)}"

      fields when fields != [] ->
        Enum.map_join(fields, " · ", &field_label/1)

      [] ->
        "Runbook"
    end
  end

  defp issue_label(_path), do: "Runbook"

  defp index_label(value) do
    case Integer.parse(value) do
      {index, ""} -> Integer.to_string(index + 1)
      _other -> value
    end
  end

  defp field_suffix([]), do: ""

  defp field_suffix(fields), do: " · " <> Enum.join(field_labels(fields), " · ")

  defp field_labels(["outputs", index | fields]),
    do: ["Output #{index_label(index)}" | Enum.map(fields, &field_label/1)]

  defp field_labels(["success", index | fields]),
    do: ["Condition #{index_label(index)}" | Enum.map(fields, &field_label/1)]

  defp field_labels(fields), do: Enum.map(fields, &field_label/1)

  defp field_label(field),
    do: field |> String.replace("_", " ") |> String.capitalize()

  defp populated_input?(input) do
    Enum.any?(
      ~w[id description default minimum maximum min_length max_length],
      &(String.trim(to_string(input[&1] || "")) != "")
    ) or input["enum_values"] != []
  end

  defp canonical_definition(draft) do
    draft
    |> RunbookDraft.command()
    |> Runbooks.build_definition_v1()
    |> Jason.encode!(pretty: true)
  end

  defp field_error(form, field) do
    case form[field].errors do
      [error | _] -> translate_error(error)
      [] -> nil
    end
  end

  defp publish_ready?(assigns) do
    not assigns.read_only? and is_nil(assigns.authoring_error) and changed_or_draft?(assigns) and
      assigns.form.source.valid? and
      assigns.definition_issues == [] and assigns.preview.state == :ready
  end

  defp publish_blocker(assigns) do
    cond do
      publish_ready?(assigns) ->
        nil

      not is_nil(assigns.authoring_error) ->
        authoring_access_message(assigns.authoring_error)

      not assigns.form.source.valid? ->
        "Fix the errors in Details before publishing."

      assigns.definition_issues != [] ->
        issue_count = length(assigns.definition_issues)

        "Fix the #{issue_count} definition #{if issue_count == 1, do: "issue", else: "issues"} before publishing."

      not changed_or_draft?(assigns) ->
        "Make a change before publishing a new release."

      assigns.preview.state == :loading ->
        "Wait for the publish check to finish."

      assigns.preview.state == :blocked ->
        "Resolve the issues before publishing."

      assigns.preview.state == :unavailable ->
        "Current runners and actions could not be checked."

      true ->
        "Publishing is unavailable."
    end
  end

  defp draft_save_ready?(assigns) do
    not assigns.read_only? and is_nil(assigns.authoring_error) and assigns.dirty? and
      assigns.form.source.valid?
  end

  # An author can keep editing a draft whose targets are outside current access.
  defp draft_save_blocker(assigns) do
    cond do
      draft_save_ready?(assigns) -> nil
      not is_nil(assigns.authoring_error) -> authoring_access_message(assigns.authoring_error)
      not assigns.dirty? -> "No unsaved changes."
      true -> "Fix the errors in Details before saving."
    end
  end

  @doc "The action-access restriction shared by editor controls and refused writes."
  def authoring_access_message(:target_out_of_scope),
    do: "Choose runners within your action access before saving or publishing."

  def authoring_access_message(:pack_out_of_scope),
    do: "Choose packs within your action access before saving or publishing."

  def authoring_access_message(_reason), do: "You no longer have permission to save or publish."

  defp changed_or_draft?(assigns) do
    assigns.dirty? or
      (not is_nil(assigns.runbook) and not is_nil(assigns.runbook.draft_definition))
  end

  # Discarding falls back to the live release, so a runbook that has never
  # published one has nothing to fall back to.
  defp discardable?(%Runbooks.Runbook{live_version: nil}), do: false
  defp discardable?(%Runbooks.Runbook{}), do: true
  defp discardable?(_runbook), do: false

  # A clean editor over a published release has nothing to publish, so the same
  # resolution check answers a different question: would Run dispatch the live
  # release right now.
  defp live_in_sync?(%Runbooks.Runbook{live_version: version, draft_definition: nil}, dirty?)
       when is_integer(version),
       do: not dirty?

  defp live_in_sync?(_runbook, _dirty?), do: false

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:runbooks}
      width={:table}
    >
      <:title>
        <%!-- One runbook, one editor: its direct parent is always the list. --%>
        <.detail_header
          back="Runbooks"
          navigate={~p"/app/#{@current_account}/runbooks"}
          title={if(@runbook, do: @runbook.title, else: "New runbook")}
        />
      </:title>

      <.page_intro>
        Choose actions and target runners, then organize them into stages. Save your workflow
        as a draft or publish it when ready.
        <.doc_link href={~p"/docs/runbooks"}>Runbook docs</.doc_link>
      </.page_intro>

      <div :if={not @loaded?} class="mt-8">
        <div role="status" class="flex items-center gap-2 text-sm text-zinc-400">
          <.icon name="state.loading" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
          Loading runbook…
        </div>
      </div>

      <div :if={@loaded?} class="mt-4 space-y-8">
        <.event_block
          :if={@read_only?}
          icon="state.locked"
          tone={:neutral}
          title="Read-only runbook"
        >
          <:body>
            You can view this runbook but can't edit or publish it. Ask an owner or admin to
            grant you an operator role.
          </:body>
        </.event_block>

        <.event_block
          :if={@catalog_load_error?}
          icon="state.warning"
          tone={:rose}
          title="Couldn't load runners and actions"
        >
          <:body>
            You can keep editing the draft. Publishing stays unavailable until current runners and
            actions can be checked.
          </:body>
        </.event_block>

        <.lifecycle_facts
          :if={@runbook}
          id="runbook-lifecycle-mobile"
          class="xl:hidden"
          runbook={@runbook}
          dirty?={@dirty?}
        />

        <.editor_actions
          :if={not @read_only?}
          id="runbook-actions-mobile"
          class="xl:hidden"
          publish_blocker={publish_blocker(assigns)}
          save_blocker={draft_save_blocker(assigns)}
          publish_review={@publish_review}
        />

        <form
          id="runbook-editor-form"
          phx-change="draft_changed"
          class="grid grid-cols-1 gap-x-12 gap-y-10 xl:grid-cols-[minmax(0,1fr)_340px]"
        >
          <main class="space-y-10 xl:col-start-1 xl:row-start-1">
            <.context_section draft={@draft} read_only?={@read_only?} />
            <.inputs_section
              draft={@draft}
              read_only?={@read_only?}
            />

            <section id="runbook-stages">
              <.section_header title="Stages">
                <:subtitle>
                  Stages run in order. Every action in a stage must succeed before the next
                  stage starts. Within a stage, actions can run sequentially or in parallel.
                </:subtitle>
              </.section_header>

              <RunbookWorkflowComponents.action_pool pool={@action_pool} />
              <div class="space-y-6">
                <RunbookWorkflowComponents.stage_editor
                  :for={{stage, stage_index} <- Enum.with_index(@draft["stages"])}
                  stage={stage}
                  stage_index={stage_index}
                  total_stages={length(@draft["stages"])}
                  draft={@draft}
                  catalog={@catalog}
                  catalog_generation={@catalog_generation}
                  open_panels={@open_panels}
                  definition_issues={@definition_issues}
                  read_only?={@read_only?}
                />
              </div>

              <.add_row
                label="Add stage"
                class="mt-6"
                phx-click="add_stage"
                disabled={@read_only?}
              />
            </section>
          </main>

          <aside class="space-y-8 xl:sticky xl:top-6 xl:col-start-2 xl:row-start-1 xl:self-start">
            <.lifecycle_facts
              :if={@runbook}
              id="runbook-lifecycle-desktop"
              class="hidden xl:block"
              runbook={@runbook}
              dirty?={@dirty?}
            />
            <.details_panel draft={@draft} form={@form} read_only?={@read_only?} />
            <.editor_actions
              :if={not @read_only?}
              id="runbook-actions-desktop"
              class="hidden xl:block"
              publish_blocker={publish_blocker(assigns)}
              save_blocker={draft_save_blocker(assigns)}
              publish_review={@publish_review}
            />
            <.publish_panel
              preview={@preview}
              definition_issues={@definition_issues}
              pristine?={is_nil(@runbook) and not @dirty?}
              runbook={@runbook}
              dirty?={@dirty?}
            />
            <.canonical_panel draft={@draft} />
            <.confirm_button
              :if={not @read_only? and discardable?(@runbook)}
              id="discard-runbook-draft"
              title="Discard the unpublished changes?"
              confirm_label="Discard changes"
              icon="action.undo"
              variant={:secondary}
              tone={if changed_or_draft?(assigns), do: :amber, else: :neutral}
              disabled={not changed_or_draft?(assigns)}
              aria-label="Discard changes"
              class="w-full justify-center"
              on_confirm={JS.push("discard_draft")}
            >
              <:body>
                Discard these workflow changes and return to v{@runbook.live_version}.
              </:body>
              Discard changes
            </.confirm_button>
            <%!-- Deleting is lifecycle, not authoring: an operator may write,
                 publish and discard this runbook but never end it, so the
                 control follows `manage` while the rest of the editor follows
                 `author`. --%>
            <.confirm_button
              :if={
                not @read_only? and not is_nil(@runbook) and
                  Runbooks.subject_can_manage_runbooks?(@current_subject)
              }
              id="delete-runbook"
              title="Delete this runbook?"
              confirm_label="Delete"
              icon="action.delete"
              variant={:secondary}
              tone={:rose}
              class="w-full justify-center"
              on_confirm={JS.push("delete")}
            >
              <:body>
                Removes this runbook and its draft. Existing executions continue.
              </:body>
              Delete
            </.confirm_button>
          </aside>
        </form>
      </div>
    </.console_shell>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :publish_blocker, :string, default: nil
  attr :save_blocker, :string, default: nil
  attr :publish_review, :map, default: nil

  defp editor_actions(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <div :if={is_nil(@publish_review)} class="grid grid-cols-2 gap-3">
        <.editor_action_button
          id={"#{@id}-publish"}
          label="Publish"
          event="review_publish"
          pending_label="Opening…"
          variant={if is_nil(@publish_blocker), do: :primary, else: :secondary}
          blocked_reason={@publish_blocker}
          align={:left}
        />
        <.editor_action_button
          id={"#{@id}-save"}
          label="Save draft"
          event="save"
          pending_label="Saving…"
          variant={:secondary}
          blocked_reason={@save_blocker}
          align={:right}
        />
      </div>
      <.publish_review :if={@publish_review} id={"#{@id}-review"} review={@publish_review} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :review, :map, required: true

  # The confirm step: what publishing changes about the live release sits beside
  # the button that does it, so the decision is made against the artifact rather
  # than a remembered one.
  defp publish_review(assigns) do
    ~H"""
    <div id={@id} class="space-y-4 rounded-xl bg-zinc-950/40 p-5 ring-1 ring-white/10">
      <p :if={is_nil(@review.diff)} class="text-xs leading-relaxed text-zinc-400">
        Publish v{@review.next_version} to make this workflow available to run.
      </p>
      <div :if={@review.diff} class="space-y-3">
        <p class="text-xs leading-relaxed text-zinc-400">
          These changes replace the published workflow. Existing executions keep their current plan.
        </p>
        <.publish_diff diff={@review.diff} />
      </div>
      <div class="flex items-center justify-end gap-3">
        <.button type="button" variant={:secondary} size={:md} phx-click="cancel_publish">
          Cancel
        </.button>
        <.button
          id={"#{@id}-confirm"}
          type="button"
          size={:md}
          phx-click="publish"
          phx-disable-with="Publishing…"
        >
          Publish v{@review.next_version}
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :runbook, :any, required: true
  attr :dirty?, :boolean, required: true

  defp lifecycle_facts(assigns) do
    ~H"""
    <dl id={@id} class={["space-y-2 text-xs text-zinc-400", @class]}>
      <.kv label="Published version">
        {if(@runbook.live_version, do: "v#{@runbook.live_version}", else: "Not published")}
      </.kv>
      <%!-- The number Publish will mint, present exactly while the editor's
           content diverges from live — "Draft: Unpublished changes" was a
           label and its synonym, saying nothing the row below could act on. --%>
      <.kv :if={@runbook.draft_definition || @dirty?} label="Next version">
        v{(@runbook.live_version || 0) + 1}
      </.kv>
    </dl>
    """
  end

  attr :diff, :any, required: true

  defp publish_diff(%{diff: %{hunks: []}} = assigns) do
    ~H"""
    <p class="text-xs text-zinc-400">
      The definition is identical. Only the title or description changed.
    </p>
    """
  end

  defp publish_diff(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <div :for={{hunk, index} <- Enum.with_index(@diff.hunks)}>
        <div :if={index > 0} class="my-2 border-t border-dashed border-zinc-800"></div>
        <%!-- The JSON indentation is content, so it rides a glued one-line
              `whitespace-pre` span: putting the class on the block would turn
              this template's own newlines into rendered leading whitespace. --%>
        <div :for={line <- hunk} class={["font-mono text-[11px] leading-5", diff_line_class(line)]}>
          <span class="whitespace-pre">{diff_line(line)}</span>
        </div>
      </div>
      <p :if={@diff.truncated?} class="mt-2 text-xs text-zinc-400">
        Diff truncated. Open the definition to read the rest.
      </p>
    </div>
    """
  end

  # Unified-diff prefixes, so the change survives being copied out of the
  # browser and reads without relying on colour alone.
  defp diff_line({:ins, text}), do: "+ " <> text
  defp diff_line({:del, text}), do: "- " <> text
  defp diff_line({:eq, text}), do: "  " <> text

  # Deliberate exception to "informative content stays neutral": +/- red-green
  # is the one diff convention every operator already reads, and this IS the
  # decision surface for publishing. Muted tier, and the glyph leads.
  defp diff_line_class({:ins, _text}), do: "bg-brand-500/[0.07] text-brand-300"
  defp diff_line_class({:del, _text}), do: "bg-rose-500/[0.07] text-rose-300"
  defp diff_line_class({:eq, _text}), do: "text-zinc-500"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :event, :string, required: true
  attr :pending_label, :string, required: true
  attr :variant, :atom, required: true
  attr :blocked_reason, :string, default: nil
  attr :align, :atom, required: true

  defp editor_action_button(assigns) do
    ~H"""
    <.tooltip
      :if={@blocked_reason}
      id={"#{@id}-reason"}
      text={@blocked_reason}
      placement={:bottom}
      align={@align}
      class="w-full flex-col"
    >
      <.button
        id={@id}
        type="button"
        variant={@variant}
        disabled
        class="w-full justify-center"
      >
        {@label}
      </.button>
    </.tooltip>
    <.button
      :if={is_nil(@blocked_reason)}
      id={@id}
      type="button"
      variant={@variant}
      phx-click={@event}
      phx-disable-with={@pending_label}
      class="w-full justify-center"
    >
      {@label}
    </.button>
    """
  end

  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp context_section(assigns) do
    ~H"""
    <section>
      <.section_header title="Instructions">
        <:subtitle>
          Explain when to use this runbook, any prerequisites, and the expected outcome.
          Markdown supported.
        </:subtitle>
      </.section_header>
      <.input
        type="textarea"
        name="draft[context_markdown]"
        value={@draft["context_markdown"]}
        rows="7"
        disabled={@read_only?}
        phx-debounce="300"
        aria-label="Instructions in Markdown"
        class="font-mono text-xs"
      />
      <details :if={String.trim(@draft["context_markdown"]) != ""} class="mt-3">
        <summary class="cursor-pointer text-xs font-medium text-zinc-400 hover:text-zinc-200">
          Preview
        </summary>
        <RunbookMarkdown.render
          markdown={@draft["context_markdown"]}
          class="mt-4 rounded-xl border border-zinc-800/70 p-5"
        />
      </details>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp inputs_section(assigns) do
    ~H"""
    <section id="runbook-inputs">
      <.section_header title="Inputs">
        <:subtitle>
          Values supplied when starting the runbook. Mark sensitive inputs to hide their values
          in plans, approvals, and results.
        </:subtitle>
      </.section_header>

      <p
        :if={@read_only? and @draft["inputs"] == []}
        class="mb-3 text-xs leading-relaxed text-zinc-400"
      >
        No inputs.
      </p>

      <div class="max-w-5xl space-y-6">
        <div
          :for={{input, index} <- Enum.with_index(@draft["inputs"])}
          id={"runbook-input-#{index}"}
          class="rounded-xl bg-zinc-950/40 p-5 ring-1 ring-white/10"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h3 class="truncate font-mono text-sm font-medium text-zinc-200">
                {input_card_title(input, index)}
              </h3>
              <p class="mt-1 text-xs text-zinc-400">
                Input {index + 1} · {input_type_label(input["type"])}
              </p>
            </div>
            <.icon_button
              :if={not @read_only?}
              icon="action.delete"
              label="Remove input"
              phx-click={
                if populated_input?(input),
                  do: open_confirm("remove-input-#{index}-confirm"),
                  else: JS.push("remove_input", value: %{index: index})
              }
            />
            <.confirm_dialog
              :if={not @read_only? and populated_input?(input)}
              id={"remove-input-#{index}-confirm"}
              title="Remove this input?"
              confirm_label="Remove input"
              on_confirm={
                JS.push("remove_input", value: %{index: index})
                |> close_confirm("remove-input-#{index}-confirm")
              }
            >
              <:body>
                Removes
                <span class="font-medium text-zinc-200">{input_card_title(input, index)}</span>
                — everything entered on it is discarded.
              </:body>
            </.confirm_dialog>
          </div>

          <div class="mt-6 space-y-6">
            <div class="grid gap-4 sm:grid-cols-[16rem_minmax(0,1fr)]">
              <.input
                size={:compact}
                name={"draft[inputs][#{index}][id]"}
                value={input["id"]}
                label="Input ID"
                label_variant={:eyebrow}
                disabled={@read_only?}
                class="font-mono"
              />
              <.input
                size={:compact}
                name={"draft[inputs][#{index}][description]"}
                value={input["description"]}
                label="Description"
                label_variant={:eyebrow}
                disabled={@read_only?}
                placeholder="What value should be supplied"
              />
            </div>

            <div class="grid gap-4 sm:grid-cols-[minmax(0,1fr)_9rem_9rem] sm:items-end">
              <.input
                size={:compact}
                type="select"
                name={"draft[inputs][#{index}][type]"}
                value={input["type"]}
                label="Type"
                label_variant={:eyebrow}
                disabled={@read_only?}
                options={[
                  {"String — text", "string"},
                  {"Integer — whole numbers", "integer"},
                  {"Number — decimals allowed", "number"},
                  {"Boolean — true or false", "boolean"},
                  {"Enum — allowed values", "enum"}
                ]}
              />
              <RunbookWorkflowComponents.qualifier_checkbox
                name={"draft[inputs][#{index}][required]"}
                label="Required"
                checked={input["required"] == "true"}
                disabled={@read_only?}
              />
              <RunbookWorkflowComponents.qualifier_checkbox
                name={"draft[inputs][#{index}][sensitive]"}
                label="Sensitive"
                checked={input["sensitive"] == "true"}
                disabled={@read_only?}
              />
            </div>

            <div :if={input["type"] == "enum"}>
              <.label variant={:eyebrow}>Allowed values</.label>
              <p :if={input["enum_values"] == []} class="mt-2 text-xs text-zinc-400">
                Add at least one value.
              </p>
              <div class="mt-3 space-y-3">
                <div
                  :for={{enum_value, value_index} <- Enum.with_index(input["enum_values"])}
                  id={"runbook-input-#{index}-enum-value-#{value_index}"}
                  class="grid grid-cols-[minmax(0,1fr)_6.5rem_2.5rem] items-start gap-2"
                >
                  <.input
                    size={:compact}
                    name={"draft[inputs][#{index}][enum_values][#{value_index}][value]"}
                    value={enum_value["value"]}
                    aria-label={"Allowed value #{value_index + 1}"}
                    disabled={@read_only?}
                  />
                  <input
                    type="hidden"
                    name={"draft[inputs][#{index}][enum_values][#{value_index}][default]"}
                    value={enum_value["default"]}
                  />
                  <button
                    type="button"
                    aria-label={enum_default_label(enum_value)}
                    aria-pressed={to_string(enum_default?(enum_value))}
                    title={enum_default_label(enum_value)}
                    phx-click="toggle_enum_default"
                    phx-value-input={index}
                    phx-value-enum={value_index}
                    disabled={
                      @read_only? or input["sensitive"] == "true" or
                        String.trim(enum_value["value"] || "") == ""
                    }
                    class={[
                      "relative mt-1 inline-flex min-h-8 w-full items-center justify-center gap-2 rounded-lg px-2 text-xs font-medium ring-1 ring-inset transition-colors after:absolute after:inset-x-0 after:-inset-y-1 after:content-[''] disabled:cursor-not-allowed disabled:opacity-40",
                      if(enum_default?(enum_value),
                        do: "bg-white/[0.04] text-zinc-100 ring-white/25",
                        else:
                          "text-zinc-400 ring-zinc-800 hover:bg-white/[0.04] hover:text-zinc-200 hover:ring-zinc-700"
                      )
                    ]}
                  >
                    <span class={[
                      "flex h-4 w-4 items-center justify-center rounded-full ring-1 ring-inset",
                      if(enum_default?(enum_value),
                        do: "ring-zinc-300",
                        else: "ring-zinc-600"
                      )
                    ]}>
                      <span
                        :if={enum_default?(enum_value)}
                        class="h-2 w-2 rounded-full bg-zinc-200"
                      />
                    </span>
                    Default
                  </button>
                  <.icon_button
                    :if={not @read_only?}
                    icon="action.delete"
                    size={:compact}
                    class="-ml-1"
                    label="Remove allowed value"
                    phx-click="remove_enum_value"
                    phx-value-input={index}
                    phx-value-enum={value_index}
                  />
                </div>
                <.add_row
                  :if={not @read_only?}
                  label="Add value"
                  phx-click="add_enum_value"
                  phx-value-index={index}
                  disabled={length(input["enum_values"]) >= 100}
                />
              </div>
            </div>

            <div
              :if={input["type"] != "enum"}
              id={"runbook-input-#{index}-default-bounds"}
              class="grid gap-4 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1fr)]"
            >
              <.input
                :if={input["type"] == "string"}
                size={:compact}
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                placeholder="No default"
              />
              <.input
                :if={input["type"] == "integer"}
                size={:compact}
                type="number"
                step="1"
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                placeholder="No default"
              />
              <.input
                :if={input["type"] == "number"}
                size={:compact}
                type="number"
                step="any"
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                placeholder="No default"
              />
              <.input
                :if={input["type"] == "boolean"}
                size={:compact}
                type="select"
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                options={[{"No default", ""}, {"True", "true"}, {"False", "false"}]}
              />
              <.input
                :if={input["type"] in ["integer", "number"]}
                size={:compact}
                type="number"
                step={if(input["type"] == "integer", do: "1", else: "any")}
                name={"draft[inputs][#{index}][minimum]"}
                value={input["minimum"]}
                label="Minimum value"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                :if={input["type"] in ["integer", "number"]}
                size={:compact}
                type="number"
                step={if(input["type"] == "integer", do: "1", else: "any")}
                name={"draft[inputs][#{index}][maximum]"}
                value={input["maximum"]}
                label="Maximum value"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                :if={input["type"] == "string"}
                size={:compact}
                type="number"
                min="0"
                name={"draft[inputs][#{index}][min_length]"}
                value={input["min_length"]}
                label="Minimum length"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                :if={input["type"] == "string"}
                size={:compact}
                type="number"
                min="0"
                name={"draft[inputs][#{index}][max_length]"}
                value={input["max_length"]}
                label="Maximum length"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
            </div>
          </div>
        </div>
        <.add_row
          :if={not @read_only?}
          label="Add input"
          phx-click="add_input"
        />
      </div>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :form, :map, required: true
  attr :read_only?, :boolean, required: true

  defp details_panel(assigns) do
    ~H"""
    <section>
      <.section_header title="Details" />
      <div class="space-y-4">
        <.input
          name="draft[title]"
          value={@draft["title"]}
          label="Title"
          label_variant={:eyebrow}
          required
          disabled={@read_only?}
          errors={List.wrap(field_error(@form, :title))}
          placeholder="Postgres replication recovery"
        />
        <.input
          name="draft[slug]"
          value={@draft["slug"]}
          label="Slug"
          label_variant={:eyebrow}
          disabled={@read_only?}
          errors={List.wrap(field_error(@form, :slug))}
          class="font-mono text-xs"
          placeholder="Generated from title"
        />
        <.input
          type="textarea"
          name="draft[description]"
          value={@draft["description"]}
          label="Description"
          label_variant={:eyebrow}
          rows="3"
          disabled={@read_only?}
          errors={List.wrap(field_error(@form, :description))}
          placeholder="What this runbook changes and when to use it"
        />
      </div>
    </section>
    """
  end

  attr :preview, :map, required: true
  attr :definition_issues, :list, required: true
  attr :pristine?, :boolean, required: true
  attr :runbook, :any, required: true
  attr :dirty?, :boolean, required: true

  defp publish_panel(assigns) do
    {panel_title, blocked_title, ready_title, ready_body} =
      if live_in_sync?(assigns.runbook, assigns.dirty?) do
        {"Run check", "Resolve these issues before running", "Checks passed",
         "The workflow passes checks for current runners, actions, pack trust, and policy."}
      else
        {"Publish check", "Resolve these issues before publishing", "Ready to publish",
         "The workflow passes checks for current runners, actions, pack trust, and policy."}
      end

    assigns =
      assigns
      |> assign(:panel_title, panel_title)
      |> assign(:blocked_title, blocked_title)
      |> assign(:ready_title, ready_title)
      |> assign(:ready_body, ready_body)

    ~H"""
    <section>
      <.section_header title={@panel_title} />

      <.event_block
        :if={@pristine? and @definition_issues != []}
        icon="product.runbook"
        tone={:neutral}
        title="Build the first stage"
      >
        <:body>
          Choose runners and an action to build your first stage.
        </:body>
      </.event_block>

      <.event_block
        :if={not @pristine? and @definition_issues != []}
        icon="state.warning"
        tone={:rose}
        title={"#{length(@definition_issues)} definition #{if length(@definition_issues) == 1, do: "issue", else: "issues"}"}
      >
        <:body>
          <ul class="space-y-2">
            <li :for={issue <- @definition_issues}>
              <a
                href={"##{issue_target(issue.path)}"}
                class="text-xs font-medium text-brand-300 hover:text-brand-200"
              >
                {issue_label(issue.path)}
              </a>
              — {issue.message}
            </li>
          </ul>
        </:body>
      </.event_block>

      <div
        :if={@definition_issues == [] and @preview.state == :loading}
        class="flex items-center gap-2 text-xs text-zinc-400"
      >
        <.icon name="state.loading" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
        Checking runners, packs, trust, and policy…
      </div>

      <.event_block
        :if={@definition_issues == [] and @preview.state == :blocked}
        icon="state.disabled"
        tone={:rose}
        title={@blocked_title}
      >
        <:body>
          <ul class="space-y-2">
            <li :for={issue <- @preview.issues}>
              <a
                href={"##{issue_target(issue.path)}"}
                class="text-xs font-medium text-brand-300 hover:text-brand-200"
              >
                {issue_label(issue.path)}
              </a>
              — {issue.message}
            </li>
          </ul>
        </:body>
      </.event_block>

      <p :if={@preview.state == :unavailable} class="text-xs leading-relaxed text-zinc-400">
        Current runners and actions could not be checked.
      </p>

      <div :if={@preview.state == :ready} class="space-y-4">
        <.event_block icon="state.success" tone={:brand} title={@ready_title}>
          <:body>
            {@ready_body}
          </:body>
        </.event_block>
      </div>
      <div :if={not is_nil(@preview.plan)} class="mt-4 space-y-2">
        <p :if={@preview.state != :ready} class="text-xs font-medium text-zinc-300">
          Previous check
        </p>
        <dl class="space-y-2 text-xs text-zinc-400">
          <.kv label="Stages">{length(@preview.plan["stages"])}</.kv>
          <.kv label="Actions">{@preview.plan["total_items"]}</.kv>
          <.kv label="Approval required">
            {if @preview.plan["approval_required"], do: "Yes", else: "No"}
          </.kv>
          <.kv label="Last checked">
            <.local_time value={@preview.checked_at} mode={:relative} />
          </.kv>
        </dl>
      </div>
    </section>
    """
  end

  attr :draft, :map, required: true

  defp canonical_panel(assigns) do
    ~H"""
    <details>
      <summary class="cursor-pointer text-xs font-medium text-zinc-300 hover:text-zinc-100">
        Runbook JSON
      </summary>
      <p class="mt-2 text-xs leading-relaxed text-zinc-400">
        The JSON definition of the workflow currently in the editor.
      </p>
      <.code_panel
        id="runbook-canonical-json"
        label="Definition v1"
        code={canonical_definition(@draft)}
        copy
        wrap
        max_h="max-h-96"
        class="mt-4"
      />
    </details>
    """
  end

  defp input_card_title(%{"id" => id}, index) do
    case String.trim(id) do
      "" -> "Input #{index + 1}"
      id -> id
    end
  end

  defp enum_default?(enum_value), do: enum_value["default"] == "true"

  defp enum_default_label(enum_value) do
    value =
      case String.trim(enum_value["value"] || "") do
        "" -> "this allowed value"
        value -> value
      end

    if enum_default?(enum_value),
      do: "Remove default: #{value}",
      else: "Use as default: #{value}"
  end

  defp input_type_label("string"), do: "String"
  defp input_type_label("integer"), do: "Integer"
  defp input_type_label("number"), do: "Number"
  defp input_type_label("boolean"), do: "Boolean"
  defp input_type_label("enum"), do: "Enum"
  defp input_type_label(_type), do: "Input"
end

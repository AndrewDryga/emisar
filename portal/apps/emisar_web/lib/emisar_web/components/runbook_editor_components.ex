defmodule EmisarWeb.RunbookEditorComponents do
  @moduledoc false

  use EmisarWeb, :html
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

  defp canonical_definition(draft),
    do: draft |> RunbookDraft.definition() |> Jason.encode!(pretty: true)

  defp field_error(form, field) do
    case form[field].errors do
      [error | _] -> translate_error(error)
      [] -> nil
    end
  end

  defp publish_ready?(assigns) do
    changed_or_draft? =
      assigns.dirty? or
        (not is_nil(assigns.runbook) and assigns.runbook.status == :draft)

    not assigns.read_only? and changed_or_draft? and assigns.form.source.valid? and
      assigns.definition_issues == [] and assigns.preview.state == :ready
  end

  defp draft_save_ready?(assigns) do
    not assigns.read_only? and assigns.dirty? and assigns.form.source.valid?
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
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
        <.detail_header
          back="Runbooks"
          navigate={~p"/app/#{@current_account}/runbooks"}
          title={if(@runbook, do: @runbook.title, else: "New runbook")}
        />
      </:title>

      <div :if={not @loaded?} class="mt-8">
        <div role="status" class="flex items-center gap-2 text-sm text-zinc-400">
          <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
          Loading runbook…
        </div>
      </div>

      <div :if={@loaded?} class="mt-4 space-y-8">
        <.event_block
          :if={@read_only?}
          icon="hero-lock-closed"
          tone={:neutral}
          title="Read-only runbook"
        >
          <:body>
            You can inspect the definition and its current validation state. Owners and admins can
            create a new version.
          </:body>
        </.event_block>

        <.event_block
          :if={@catalog_load_error?}
          icon="hero-exclamation-triangle"
          tone={:rose}
          title="Current catalog could not be loaded"
        >
          <:body>
            You can keep editing the draft. Publishing stays unavailable until current runners and
            actions can be checked.
          </:body>
        </.event_block>

        <div :if={not @read_only?} class="xl:hidden">
          <.editor_actions
            runbook={@runbook}
            dirty?={@dirty?}
            publish_ready?={publish_ready?(assigns)}
            save_ready?={draft_save_ready?(assigns)}
            read_only?={@read_only?}
          />
        </div>

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
                  A stage is a barrier. Every step must succeed before the next stage starts.
                </:subtitle>
              </.section_header>

              <div class="space-y-6">
                <RunbookWorkflowComponents.stage_editor
                  :for={{stage, stage_index} <- Enum.with_index(@draft["stages"])}
                  stage={stage}
                  stage_index={stage_index}
                  total_stages={length(@draft["stages"])}
                  draft={@draft}
                  catalog={@catalog}
                  open_panels={@open_panels}
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
            <div :if={not @read_only?} class="hidden xl:block">
              <.editor_actions
                runbook={@runbook}
                dirty?={@dirty?}
                publish_ready?={publish_ready?(assigns)}
                save_ready?={draft_save_ready?(assigns)}
                read_only?={@read_only?}
              />
            </div>
            <.details_panel draft={@draft} form={@form} read_only?={@read_only?} />
            <.publish_panel
              preview={@preview}
              definition_issues={@definition_issues}
              pristine?={is_nil(@runbook) and not @dirty?}
            />
            <.canonical_panel draft={@draft} />
            <.confirm_button
              :if={not @read_only? and @runbook}
              id="delete-runbook"
              title="Delete this runbook?"
              confirm_label="Delete runbook"
              icon="hero-trash"
              variant={:secondary}
              tone={:rose}
              class="w-full justify-center"
              on_confirm={JS.push("delete")}
            >
              <:body>
                Removes every version in this runbook family. Existing execution history remains.
              </:body>
              Delete runbook
            </.confirm_button>
          </aside>
        </form>
      </div>
    </.dashboard_shell>
    """
  end

  attr :runbook, :any, default: nil
  attr :dirty?, :boolean, required: true
  attr :publish_ready?, :boolean, required: true
  attr :save_ready?, :boolean, required: true
  attr :read_only?, :boolean, required: true

  defp editor_actions(assigns) do
    ~H"""
    <section>
      <.section_header title="Actions" />
      <div class="grid grid-cols-2 gap-3">
        <.button
          type="button"
          variant={if @publish_ready?, do: :primary, else: :secondary}
          phx-click="publish"
          phx-disable-with="Publishing…"
          disabled={not @publish_ready?}
          class="justify-center"
        >
          Publish
        </.button>
        <.button
          type="button"
          variant={:secondary}
          phx-click="save"
          phx-disable-with="Saving…"
          disabled={not @save_ready?}
          class="justify-center"
        >
          Save draft
        </.button>
      </div>
      <dl :if={@runbook} class="mt-4 space-y-2 text-xs text-zinc-400">
        <.kv label="Current">v{@runbook.version}</.kv>
        <.kv label="Status"><.status_badge status={@runbook.status} /></.kv>
        <.kv :if={@dirty? and not @read_only?} label="Next">v{@runbook.version + 1}</.kv>
      </dl>
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp context_section(assigns) do
    ~H"""
    <section>
      <.section_header title="Operator context">
        <:subtitle>
          Markdown shown before execution. Record prerequisites, stop conditions, and the expected
          outcome.
        </:subtitle>
      </.section_header>
      <.input
        type="textarea"
        name="draft[context_markdown]"
        value={@draft["context_markdown"]}
        rows="7"
        disabled={@read_only?}
        phx-debounce="300"
        aria-label="Operator context in Markdown"
        class="font-mono text-xs"
      />
      <details :if={String.trim(@draft["context_markdown"]) != ""} class="mt-3">
        <summary class="cursor-pointer text-xs font-medium text-zinc-400 hover:text-zinc-200">
          Preview context
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
      <.section_header title="Run-time inputs">
        <:subtitle>
          Typed values supplied when the run starts. Sensitive values are never shown in plans or
          results.
        </:subtitle>
      </.section_header>

      <p :if={@draft["inputs"] == []} class="mb-3 text-xs leading-relaxed text-zinc-500">
        No run-time inputs. Add one for a value that should be supplied for each execution.
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
              <p class="mt-1 text-xs text-zinc-500">
                Input {index + 1} · {input_type_label(input["type"])}
              </p>
            </div>
            <.icon_button
              :if={not @read_only?}
              icon="hero-trash"
              label="Remove input"
              phx-click="remove_input"
              phx-value-index={index}
              data-confirm={if populated_input?(input), do: "Remove this populated input?"}
            />
          </div>

          <div class="mt-6 max-w-3xl space-y-6">
            <div class="grid gap-4 sm:grid-cols-[16rem_minmax(0,1fr)]">
              <.input
                name={"draft[inputs][#{index}][id]"}
                value={input["id"]}
                label="Input ID"
                label_variant={:eyebrow}
                disabled={@read_only?}
                class="font-mono"
              />
              <.input
                name={"draft[inputs][#{index}][description]"}
                value={input["description"]}
                label="Description"
                label_variant={:eyebrow}
                disabled={@read_only?}
                placeholder="What the operator or LLM should supply"
              />
            </div>

            <div class="grid gap-4 sm:grid-cols-[minmax(0,1fr)_9rem_9rem]">
              <.input
                type="select"
                name={"draft[inputs][#{index}][type]"}
                value={input["type"]}
                label="Type"
                label_variant={:eyebrow}
                disabled={@read_only?}
                options={[
                  {"String", "string"},
                  {"Integer — whole numbers", "integer"},
                  {"Number — decimals allowed", "number"},
                  {"Boolean", "boolean"},
                  {"Enum", "enum"}
                ]}
              />
              <.input
                type="select"
                name={"draft[inputs][#{index}][required]"}
                value={input["required"]}
                label="Required"
                label_variant={:eyebrow}
                disabled={@read_only?}
                options={[{"Yes", "true"}, {"No", "false"}]}
              />
              <.input
                type="select"
                name={"draft[inputs][#{index}][sensitive]"}
                value={input["sensitive"]}
                label="Sensitive?"
                label_variant={:eyebrow}
                disabled={@read_only?}
                options={[{"No", "false"}, {"Yes — always redact", "true"}]}
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
                      "mt-2 inline-flex min-h-10 w-full items-center justify-center gap-2 rounded-lg px-3 text-xs font-medium ring-1 ring-inset transition-colors disabled:cursor-not-allowed disabled:opacity-40",
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
                    icon="hero-trash"
                    label="Remove allowed value"
                    phx-click="remove_enum_value"
                    phx-value-input={index}
                    phx-value-enum={value_index}
                    class="mt-2 rounded-lg ring-1 ring-inset ring-zinc-800"
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

            <div :if={input["type"] != "enum"}>
              <.input
                :if={input["type"] == "string"}
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                placeholder="No default"
              />
              <.input
                :if={input["type"] == "integer"}
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
                type="select"
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default value"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                options={[{"No default", ""}, {"True", "true"}, {"False", "false"}]}
              />
            </div>

            <div
              :if={input["type"] in ["integer", "number"]}
              class="grid gap-4 sm:grid-cols-2"
            >
              <.input
                type="number"
                step={if(input["type"] == "integer", do: "1", else: "any")}
                name={"draft[inputs][#{index}][minimum]"}
                value={input["minimum"]}
                label="Minimum value"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                type="number"
                step={if(input["type"] == "integer", do: "1", else: "any")}
                name={"draft[inputs][#{index}][maximum]"}
                value={input["maximum"]}
                label="Maximum value"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
            </div>

            <div
              :if={input["type"] == "string"}
              class="grid gap-4 sm:grid-cols-2"
            >
              <.input
                type="number"
                min="0"
                name={"draft[inputs][#{index}][min_length]"}
                value={input["min_length"]}
                label="Minimum length"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
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
        <p class="text-[11px] leading-relaxed text-zinc-500">
          The description appears in runbook discovery for operators and LLMs.
        </p>
      </div>
    </section>
    """
  end

  attr :preview, :map, required: true
  attr :definition_issues, :list, required: true
  attr :pristine?, :boolean, required: true

  defp publish_panel(assigns) do
    ~H"""
    <section>
      <.section_header title="Publish check" />

      <.event_block
        :if={@pristine? and @definition_issues != []}
        icon="hero-list-bullet"
        tone={:neutral}
        title="Build the first stage"
      >
        <:body>
          Choose targets and an action. Publication becomes available only after the complete
          definition resolves against current infrastructure.
        </:body>
      </.event_block>

      <.event_block
        :if={not @pristine? and @definition_issues != []}
        icon="hero-exclamation-triangle"
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
        <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
        Checking runners, packs, trust, and policy…
      </div>

      <.event_block
        :if={@definition_issues == [] and @preview.state == :blocked}
        icon="hero-no-symbol"
        tone={:rose}
        title="Current infrastructure blocks publication"
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
        Current infrastructure validation is unavailable for this read-only view.
      </p>

      <div :if={@preview.state == :ready} class="space-y-4">
        <.event_block icon="hero-check-circle" tone={:brand} title="Ready to publish">
          <:body>
            The definition is valid and resolves against current runners, trusted packs, action
            contracts, and policy.
          </:body>
        </.event_block>
        <dl class="space-y-2 text-xs text-zinc-400">
          <.kv label="Stages">{length(@preview.plan["stages"])}</.kv>
          <.kv label="Actions">{@preview.plan["total_items"]}</.kv>
          <.kv label="Run approval">
            {if @preview.plan["approval_required"], do: "Required", else: "Not required"}
          </.kv>
          <.kv label="Checked">
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
        Canonical JSON
      </summary>
      <p class="mt-2 text-xs leading-relaxed text-zinc-500">
        The exact JSON definition saved and exposed to MCP.
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

  defp input_card_title(%{"id" => id}, index) when is_binary(id) do
    case String.trim(id) do
      "" -> "Input #{index + 1}"
      id -> id
    end
  end

  defp input_card_title(_input, index), do: "Input #{index + 1}"

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

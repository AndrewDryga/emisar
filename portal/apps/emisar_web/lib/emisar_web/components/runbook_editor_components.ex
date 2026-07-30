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

  defp populated_input?(input) do
    Enum.any?(
      ~w[id description default minimum maximum min_length max_length],
      &(String.trim(to_string(input[&1] || "")) != "")
    )
  end

  defp canonical_definition(draft),
    do: draft |> RunbookDraft.definition() |> Jason.encode!(pretty: true)

  defp compact_json(value), do: Jason.encode!(value)

  defp field_error(form, field) do
    case form[field].errors do
      [error | _] -> translate_error(error)
      [] -> nil
    end
  end

  defp publish_ready?(assigns) do
    not assigns.read_only? and assigns.definition_issues == [] and
      assigns.preview.state == :ready
  end

  defp draft_save_ready?(assigns) do
    not assigns.read_only? and assigns.form.source.valid?
  end

  defp save_status(%{runbook: nil, dirty?: false}), do: "Not saved yet"
  defp save_status(%{dirty?: true}), do: "Unsaved changes"
  defp save_status(_assigns), do: "All changes saved"

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
      <:actions>
        <.button
          variant={:secondary}
          navigate={~p"/app/#{@current_account}/runbooks"}
          data-confirm={if @dirty?, do: "Discard unsaved changes?"}
        >
          {if @read_only?, do: "Back", else: "Cancel"}
        </.button>
      </:actions>

      <div :if={not @loaded?} class="mt-8">
        <div role="status" class="flex items-center gap-2 text-sm text-zinc-400">
          <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
          Loading runbook…
        </div>
      </div>

      <div :if={@loaded?} class="mt-4 space-y-10">
        <.event_block
          :if={@read_only?}
          icon="hero-lock-closed"
          tone={:neutral}
          title="Read-only runbook"
        >
          <:body>
            You can inspect the complete definition and current validation state. Owners and admins
            can create a new version.
          </:body>
        </.event_block>

        <.event_block
          :if={@catalog_load_error?}
          icon="hero-exclamation-triangle"
          tone={:rose}
          title="Current catalog could not be loaded"
        >
          <:body>
            Draft editing is still available, but current preflight and publishing are unavailable.
            Refresh the page before publishing.
          </:body>
        </.event_block>

        <div
          :if={not @read_only?}
          class="sticky top-0 z-20 flex flex-wrap items-center gap-3 bg-black/95 py-3 backdrop-blur"
        >
          <.button
            type="button"
            phx-click="publish"
            phx-disable-with="Publishing…"
            disabled={not publish_ready?(assigns)}
          >
            Publish
          </.button>
          <.button
            type="button"
            variant={:secondary}
            phx-click="save"
            phx-disable-with="Saving…"
            disabled={not draft_save_ready?(assigns)}
          >
            Save draft
          </.button>
          <span class="ml-auto text-xs text-zinc-400">
            {save_status(assigns)}
          </span>
        </div>

        <form
          id="runbook-editor-form"
          phx-change="draft_changed"
          class="grid grid-cols-1 gap-x-12 gap-y-10 xl:grid-cols-[minmax(0,1fr)_340px]"
        >
          <div class="space-y-10">
            <.details_panel draft={@draft} form={@form} read_only?={@read_only?} />
            <.context_section draft={@draft} read_only?={@read_only?} />
            <.inputs_section draft={@draft} read_only?={@read_only?} />

            <section id="runbook-stages">
              <.section_header title="Stages">
                <:subtitle>
                  Stages are barriers. Every item in one stage must succeed before the next starts.
                </:subtitle>
                <:actions>
                  <.button
                    type="button"
                    variant={:secondary}
                    size={:sm}
                    icon="hero-plus"
                    phx-click="add_stage"
                    disabled={@read_only?}
                  >
                    Add stage
                  </.button>
                </:actions>
              </.section_header>

              <div class="space-y-6">
                <RunbookWorkflowComponents.stage_editor
                  :for={{stage, stage_index} <- Enum.with_index(@draft["stages"])}
                  stage={stage}
                  stage_index={stage_index}
                  total_stages={length(@draft["stages"])}
                  draft={@draft}
                  catalog={@catalog}
                  pack_ids={@pack_ids}
                  groups={@groups}
                  runner_options={@runner_options}
                  read_only?={@read_only?}
                />
              </div>
            </section>
          </div>

          <aside class="space-y-8 xl:sticky xl:top-20 xl:self-start">
            <.publish_panel
              runbook={@runbook}
              preview={@preview}
              definition_issues={@definition_issues}
              pristine?={is_nil(@runbook) and not @dirty?}
              ready?={publish_ready?(assigns)}
              read_only?={@read_only?}
            />
            <.canonical_panel draft={@draft} />
          </aside>
        </form>

        <div :if={not @read_only? and @runbook} class="flex border-t border-zinc-800 pt-8">
          <.confirm_button
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
              Removes every version in this runbook family. Existing execution history remains.
            </:body>
            Delete runbook
          </.confirm_button>
        </div>
      </div>
    </.dashboard_shell>
    """
  end

  attr :draft, :map, required: true
  attr :read_only?, :boolean, required: true

  defp context_section(assigns) do
    ~H"""
    <section>
      <.section_header title="Operator context">
        <:subtitle>
          Markdown shown before execution. Keep prerequisites, stop conditions, and expected outcome here.
        </:subtitle>
      </.section_header>
      <.input
        type="textarea"
        name="draft[context_markdown]"
        value={@draft["context_markdown"]}
        rows="6"
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
      <.section_header title="Inputs">
        <:subtitle>
          Typed values are supplied at run time. Sensitive values are accepted for dispatch but redacted from plans and results.
        </:subtitle>
        <:actions>
          <.button
            type="button"
            variant={:secondary}
            size={:sm}
            icon="hero-plus"
            phx-click="add_input"
            disabled={@read_only?}
          >
            Add input
          </.button>
        </:actions>
      </.section_header>

      <div
        :if={@draft["inputs"] == []}
        class="rounded-xl border border-dashed border-zinc-800 px-4 py-3 text-xs leading-relaxed text-zinc-400"
      >
        No run-time inputs. Add one when an execution value should not be stored in the runbook.
      </div>

      <div class="space-y-4">
        <div
          :for={{input, index} <- Enum.with_index(@draft["inputs"])}
          class="rounded-xl border border-dashed border-zinc-800 p-5"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
              Input {index + 1}
            </span>
            <.icon_button
              icon="hero-trash"
              label="Remove input"
              phx-click="remove_input"
              phx-value-index={index}
              disabled={@read_only?}
              data-confirm={if populated_input?(input), do: "Remove this populated input?"}
            />
          </div>

          <div class="mt-4 grid gap-3 sm:grid-cols-2">
            <.input
              name={"draft[inputs][#{index}][id]"}
              value={input["id"]}
              label="Input ID"
              label_variant={:eyebrow}
              disabled={@read_only?}
              class="font-mono text-xs"
            />
            <.input
              type="select"
              name={"draft[inputs][#{index}][type]"}
              value={input["type"]}
              label="Type"
              label_variant={:eyebrow}
              disabled={@read_only?}
              options={[
                {"String", "string"},
                {"Integer", "integer"},
                {"Number", "number"},
                {"Boolean", "boolean"}
              ]}
            />
            <div class="sm:col-span-2">
              <.input
                name={"draft[inputs][#{index}][description]"}
                value={input["description"]}
                label="Description"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
            </div>
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
              label="Sensitive"
              label_variant={:eyebrow}
              disabled={@read_only?}
              options={[{"No", "false"}, {"Yes — always redact", "true"}]}
            />
          </div>

          <details class="mt-4">
            <summary class="cursor-pointer text-xs font-medium text-zinc-400 hover:text-zinc-200">
              Defaults and constraints
            </summary>
            <div class="mt-4 grid gap-3 sm:grid-cols-2">
              <.input
                type="select"
                name={"draft[inputs][#{index}][default_enabled]"}
                value={input["default_enabled"]}
                label="Persist a default"
                label_variant={:eyebrow}
                disabled={@read_only? or input["sensitive"] == "true"}
                options={[{"No", "false"}, {"Yes", "true"}]}
              />
              <.input
                :if={input["default_enabled"] == "true"}
                name={"draft[inputs][#{index}][default]"}
                value={input["default"]}
                label="Default"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                type="select"
                name={"draft[inputs][#{index}][enum_enabled]"}
                value={input["enum_enabled"]}
                label="Restrict to an enum"
                label_variant={:eyebrow}
                disabled={@read_only?}
                options={[{"No", "false"}, {"Yes", "true"}]}
              />
              <.input
                :if={input["enum_enabled"] == "true"}
                name={"draft[inputs][#{index}][enum]"}
                value={input["enum"]}
                label="Enum values (JSON array)"
                label_variant={:eyebrow}
                disabled={@read_only?}
                class="font-mono text-xs"
              />
              <.input
                :if={input["type"] in ["integer", "number"]}
                type="number"
                step="any"
                name={"draft[inputs][#{index}][minimum]"}
                value={input["minimum"]}
                label="Minimum"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                :if={input["type"] in ["integer", "number"]}
                type="number"
                step="any"
                name={"draft[inputs][#{index}][maximum]"}
                value={input["maximum"]}
                label="Maximum"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
              <.input
                :if={input["type"] == "string"}
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
                type="number"
                min="0"
                name={"draft[inputs][#{index}][max_length]"}
                value={input["max_length"]}
                label="Maximum length"
                label_variant={:eyebrow}
                disabled={@read_only?}
              />
            </div>
          </details>
        </div>
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
      <div class="grid gap-4 rounded-xl border border-zinc-800 p-5 sm:grid-cols-2">
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
          placeholder="auto from title"
        />
        <div class="sm:col-span-2">
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
      </div>
    </section>
    """
  end

  attr :runbook, :any, default: nil
  attr :preview, :map, required: true
  attr :definition_issues, :list, required: true
  attr :pristine?, :boolean, required: true
  attr :ready?, :boolean, required: true
  attr :read_only?, :boolean, required: true

  defp publish_panel(assigns) do
    ~H"""
    <section>
      <.section_header title="Publish review" />

      <.event_block
        :if={@pristine? and @definition_issues != []}
        icon="hero-list-bullet"
        tone={:neutral}
        title="Build the first stage"
      >
        <:body>
          Choose an action, compatible pack version, and at least one target. Validation and
          current-infrastructure preflight update as you work.
        </:body>
      </.event_block>

      <div :if={not @pristine? and @definition_issues != []} class="space-y-3">
        <.event_block
          icon="hero-exclamation-triangle"
          tone={:rose}
          title={"#{length(@definition_issues)} definition #{if length(@definition_issues) == 1, do: "issue", else: "issues"}"}
        >
          <:body>
            <ul class="space-y-2">
              <li :for={issue <- @definition_issues}>
                <a
                  href={"##{issue_target(issue.path)}"}
                  class="font-mono text-[11px] text-brand-300 hover:text-brand-200"
                >
                  {issue.path || "/"}
                </a>
                — {issue.message}
              </li>
            </ul>
          </:body>
        </.event_block>
      </div>

      <div :if={@definition_issues == []} class="space-y-4">
        <div
          :if={@preview.state == :loading}
          class="flex items-center gap-2 text-xs text-zinc-400"
        >
          <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin motion-reduce:animate-none" />
          Resolving current runners, packs, and trust…
        </div>

        <.event_block
          :if={@preview.state == :blocked}
          icon="hero-no-symbol"
          tone={:rose}
          title="Current preflight is blocked"
        >
          <:body>
            <ul class="space-y-2">
              <li :for={issue <- @preview.issues}>
                <a
                  href={"##{issue_target(issue.path)}"}
                  class="font-mono text-[11px] text-brand-300 hover:text-brand-200"
                >
                  {issue.path || "/"}
                </a>
                — {issue.message}
              </li>
            </ul>
          </:body>
        </.event_block>

        <p :if={@preview.state == :unavailable} class="text-xs leading-relaxed text-zinc-400">
          Current infrastructure preflight is unavailable for this read-only view.
        </p>

        <div :if={@preview.state == :ready} class="space-y-5 text-xs">
          <dl class="space-y-2 text-zinc-400">
            <.kv label="Stages">{length(@preview.plan["stages"])}</.kv>
            <.kv label="Logical actions">{@preview.plan["total_items"]}</.kv>
            <.kv label="Approval gates">
              {Enum.count(@preview.plan["stages"], &(&1["approval"] == "required"))}
            </.kv>
            <.kv label="Current check">
              <.local_time value={@preview.checked_at} mode={:relative} />
            </.kv>
          </dl>
          <p class="leading-relaxed text-zinc-400">
            Required inputs without defaults use deterministic type-safe examples for this authoring
            preview. Execution compiles again with the supplied values.
          </p>

          <div class="space-y-3">
            <details
              :for={stage <- @preview.plan["stages"]}
              class="rounded-lg border border-zinc-800/80 p-3"
              open
            >
              <summary class="cursor-pointer list-none">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="font-medium text-zinc-200">{stage["title"]}</span>
                  <span class="text-zinc-500">
                    {stage["mode"]} · max {stage["max_parallel"]} · {length(stage["items"])} items
                  </span>
                </div>
                <p class="mt-1 text-zinc-500">
                  Approval: {stage["approval"]}
                </p>
              </summary>

              <div class="mt-3 space-y-3 border-t border-zinc-800/70 pt-3">
                <article
                  :for={item <- stage["items"]}
                  class="min-w-0 rounded-md bg-zinc-900/70 p-3"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <span class="font-mono text-zinc-200">{item["runner_ref"]}</span>
                    <.risk_pill risk={item["risk"]} />
                  </div>
                  <p class="mt-1 break-all font-mono text-zinc-400">{item["action"]}</p>
                  <p class="mt-1 break-all font-mono text-zinc-500">{item["pack_ref"]}</p>
                  <dl class="mt-2 space-y-1 text-zinc-500">
                    <.kv label="Hash">
                      <span class="break-all font-mono">{item["pack_hash"]}</span>
                    </.kv>
                    <.kv label="Arguments">
                      <span class="break-all font-mono">{compact_json(item["args"])}</span>
                    </.kv>
                    <.kv label="Outputs">{length(item["outputs"])}</.kv>
                    <.kv label="Conditions">{length(item["success"])}</.kv>
                    <.kv label="Wait">{if item["wait"], do: "configured", else: "none"}</.kv>
                  </dl>
                </article>
              </div>
            </details>
          </div>
        </div>
      </div>

      <div :if={@runbook} class="mt-6 border-t border-zinc-800 pt-5">
        <dl class="space-y-2 text-xs text-zinc-400">
          <.kv label="Current">v{@runbook.version}</.kv>
          <.kv label="Status"><.status_badge status={@runbook.status} /></.kv>
          <.kv :if={not @read_only?} label="Saving creates">v{@runbook.version + 1}</.kv>
        </dl>
      </div>

      <p :if={@ready?} class="mt-5 text-xs font-medium text-brand-300">
        Ready to publish.
      </p>
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
        The exact JSON-compatible definition saved and exposed to MCP.
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
end

defmodule EmisarWeb.RunNewLive do
  use EmisarWeb, :live_view
  alias Emisar.{ActionContract, Catalog, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"runner_id" => runner_id, "action_id" => action_id}, _session, socket) do
    case Catalog.fetch_action_by_id(action_id, runner_id, socket.assigns.current_subject) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Action not found.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners/#{runner_id}")}

      {:ok, %{primary_executable_available: false}} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "This action cannot start because its primary executable is missing on the runner."
         )
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runners/#{runner_id}")}

      {:ok, action} ->
        args_schema = action.args_schema["args"] || []

        # The action fetch above gates render/redirect, so it stays in
        # mount. The runner is only used to label the page (its name in
        # the breadcrumb) — defer it behind `connected?/1` so it doesn't
        # run twice (IL-18). The dead pass shows the "Runner" fallback.
        runner = if connected?(socket), do: lookup_runner(runner_id, socket), else: nil

        {:ok,
         socket
         |> assign(:page_title, "Run #{action.action_id}")
         |> assign(:action, action)
         |> assign(:runner_id, runner_id)
         |> assign(:runner, runner)
         |> assign(:readiness, runner && Runners.runner_readiness(runner))
         |> assign(:args_schema, args_schema)
         |> assign_form(ActionContract.form_values(action))
         |> assign(:reason, "")
         |> assign(:reason_error, nil)
         |> assign(
           :can_dispatch?,
           Runs.subject_can_dispatch_run?(socket.assigns.current_subject)
         )}
    end
  end

  defp lookup_runner(runner_id, socket) do
    case Runners.fetch_runner_by_id(
           runner_id,
           socket.assigns.current_subject,
           preload: [:online?]
         ) do
      {:ok, r} -> r
      {:error, :not_found} -> nil
    end
  end

  # Every branch below reads the ONE authoritative dispatch verdict, never the
  # separate signature or connection axis — a disabled signed-only runner is
  # blocked because it's disabled, and must say so. Each is a strict boolean so
  # the dead render, where @readiness is still nil, is safe.
  defp signature_blocked?(%{portal_dispatch: %{reason: :signature_required}}), do: true
  defp signature_blocked?(_readiness), do: false

  defp dispatch_disabled?(%{portal_dispatch: %{reason: :disabled}}), do: true
  defp dispatch_disabled?(_readiness), do: false

  # A dispatch from here queues whenever the portal will accept it but can't
  # deliver it yet — offline, and equally a runner that has never connected. A
  # blocked runner is refused outright rather than queued, so its own notice
  # (below) carries that state instead.
  defp dispatch_would_queue?(%{portal_dispatch: %{state: :queueable}}), do: true
  defp dispatch_would_queue?(_readiness), do: false

  defp portal_dispatchable?(%{portal_dispatch: %{state: state}})
       when state in [:ready, :queueable],
       do: true

  defp portal_dispatchable?(_readiness), do: false

  # High/critical dispatches confirm and echo the action + target + the args
  # the operator entered, so a mis-aimed click on a destructive action is
  # caught AND they see the blast radius (which container/signal/path), not
  # just the action name. Low/medium dispatch behind just the disable-with
  # spinner (nil omits the data-confirm attr). `risk` is an Ecto.Enum atom.
  defp dispatch_confirm(%{risk: risk} = action, runner, runner_id, args_schema, form)
       when risk in [:high, :critical] do
    target = (runner && runner.name) || runner_id

    base =
      "Dispatch #{action.action_id} (#{risk} risk) to #{target} now? It runs on the host immediately."

    case args_blast_radius(args_schema, form.params) do
      "" -> base
      summary -> base <> "\n\n" <> summary
    end
  end

  defp dispatch_confirm(_action, _runner, _runner_id, _args_schema, _form), do: nil

  # The entered args in schema order, empties dropped, each value clipped so a
  # long path can't blow up the native confirm dialog.
  defp args_blast_radius(args_schema, params) do
    lines =
      Enum.flat_map(args_schema, fn arg ->
        name = arg["name"]

        case params[name] do
          value when value in [nil, ""] -> []
          value -> ["• #{name}: #{clip_arg(value)}"]
        end
      end)

    if lines == [], do: "", else: "Arguments:\n" <> Enum.join(lines, "\n")
  end

  defp clip_arg(value) do
    string = to_string(value)
    if String.length(string) > 60, do: String.slice(string, 0, 57) <> "…", else: string
  end

  def handle_event("validate", params, socket) do
    # Actions with no arg schema render only the `reason` field, so the
    # phx-change payload won't contain `"args"`. Default to the existing
    # form so the empty-args case doesn't FunctionClauseError.
    args = Map.get(params, "args", socket.assigns.form.params)
    reason = params["reason"] || socket.assigns.reason

    {:noreply,
     socket
     |> assign_form(args, arg_errors(args, socket.assigns.action))
     |> assign(:reason, reason)
     # Clear the inline error as soon as the operator fills the field in — never
     # add one here (a blank field shouldn't show "required" until they dispatch).
     |> assign(:reason_error, if(String.trim(reason) == "", do: socket.assigns.reason_error))}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(
      socket,
      Runs.subject_can_dispatch_run?(socket.assigns.current_subject),
      &do_dispatch(&1, params)
    )
  end

  defp do_dispatch(socket, params) do
    raw_args = params["args"] || %{}
    reason = params["reason"] || ""

    # A missing reason is a validation of the one operator-entered run
    # parameter, so it renders inline under the field, not in a flash.
    if String.trim(reason) == "" do
      {:noreply,
       socket
       |> assign(:reason, reason)
       |> assign(:reason_error, "Reason is required — describe why you are running this action.")}
    else
      do_dispatch_with_reason(socket, raw_args, reason)
    end
  end

  defp do_dispatch_with_reason(socket, raw_args, reason) do
    case ActionContract.cast_form(raw_args, socket.assigns.action) do
      # Bad/missing args render inline under the offending fields (rose
      # border) via the form's per-arg errors — not a flash banner.
      {:error, issues} ->
        {:noreply, assign_form(socket, raw_args, Enum.map(issues, &field_error/1))}

      {:ok, args} ->
        attrs = %{
          runner_id: socket.assigns.runner_id,
          action_id: socket.assigns.action.action_id,
          args: args,
          opts: %{},
          reason: reason,
          source: "operator",
          requested_by_id: socket.assigns.current_user.id,
          # Per-user runner ACLs (#238): pass the membership so the
          # context can reject runners outside the operator's scope.
          requested_by_membership_id: socket.assigns.current_membership.id
        }

        case Runs.dispatch_run(attrs, socket.assigns.current_subject) do
          {:ok, _status, run} ->
            {:noreply,
             push_navigate(socket, to: ~p"/app/#{socket.assigns.current_account}/runs/#{run.id}")}

          {:error, :denied_by_policy, reason} ->
            {:noreply, put_flash(socket, :error, "Denied by policy: #{reason}")}

          {:error, :runner_not_found} ->
            {:noreply, put_flash(socket, :error, "Runner not found in this account.")}

          {:error, :runner_out_of_scope} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "That runner is outside your access scope. Ask an admin to grant access on the team page."
             )}

          {:error, :runner_required} ->
            {:noreply, put_flash(socket, :error, "Runner is required.")}

          {:error, :pack_untrusted} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This runner is advertising an untrusted version of the action's pack. " <>
                 "Review and trust it on the Packs page before dispatching."
             )}

          {:error, :pack_retired} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This runner is advertising a retired version of the action's pack — a newer " <>
                 "release superseded it. Update the pack on the runner, or re-trust the version " <>
                 "on the Packs page."
             )}

          {:error, :runner_requires_attestation} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This runner only accepts signed runs from an MCP client — the portal can't " <>
                 "dispatch to it. Run the action from your MCP client instead."
             )}

          {:error, :action_not_found} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This runner no longer advertises that action — reload the page and pick a current one."
             )}

          {:error, :action_unavailable} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "This action cannot start on the runner because its primary executable is missing. Install the tool and reload the runner."
             )}

          # The run record itself was rejected (its fields key to the
          # dispatch envelope — runner_id, source, … — not to the action's
          # arguments, so there's no per-arg input to pin these on). A
          # concise flash is correct here; the inline arg errors above
          # already caught anything the operator can fix in a field.
          {:error, %Ecto.Changeset{}} ->
            {:noreply,
             put_flash(socket, :error, "Could not dispatch the run — reload and try again.")}

          # Don't swallow an unexpected error into "Something went wrong" —
          # surface the actual code so the operator (and the logs) can act.
          {:error, other} ->
            {:noreply, put_flash(socket, :error, "Dispatch failed (#{inspect(other)}).")}
        end
    end
  end

  # No-op for the broadcasts the on_mount badge/fleet hooks forward (approvals,
  # pack trust, runner presence). The hooks own those nav cues; this page ignores them.
  def handle_info(_msg, socket), do: {:noreply, socket}

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
      section={:runs}
      width={:form}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/runners"}>Runners</.back_link>
        <.back_link navigate={~p"/app/#{@current_account}/runners/#{@runner_id}"}>
          {(@runner && @runner.name) || "Runner"}
        </.back_link>
        Run <span class="font-mono text-base">{@action.action_id}</span>
      </:title>
      <div class="mt-4 space-y-12">
        <%!-- About this action, NAKED on the canvas — everything the operator
             reads before deciding: description prose, side effects, and the
             pack's canonical examples (the example frames are the earned
             artifacts). The meta row below carries risk/kind/pack, so the
             risk pill renders exactly once. --%>
        <section>
          <.section_header title={@action.title} />
          <p
            :if={@action.description && @action.description != ""}
            class="text-sm leading-relaxed text-zinc-400"
          >
            <.inline_code text={@action.description} />
          </p>

          <%!-- Side effects — amber only when this action MUTATES real
               state (risk above low). A read-only action's side-effect
               note stays neutral, so amber keeps meaning "caution". --%>
          <div
            :if={@action.side_effects && @action.side_effects != []}
            class={["mt-4", @action.description in [nil, ""] && "mt-0"]}
          >
            <div class={[
              "text-[10px] font-semibold uppercase tracking-wider",
              if(@action.risk == :low, do: "text-zinc-400", else: "text-amber-300")
            ]}>
              Side effects
            </div>
            <ul class="mt-1.5 space-y-1 text-sm text-zinc-400">
              <li :for={effect <- @action.side_effects} class="flex items-start gap-2">
                <span class={[
                  "mt-2 h-1 w-1 flex-none rounded-full",
                  if(@action.risk == :low, do: "bg-zinc-600", else: "bg-amber-300")
                ]}></span>
                <span><.inline_code text={effect} /></span>
              </li>
            </ul>
          </div>

          <%!-- Pack-provided examples — short canonical invocations
               with sample args. Big UX win when an operator has the
               form open and is wondering "what does a real call look
               like?". Only renders when the pack ships examples. --%>
          <div :if={action_examples(@action) != []} class="mt-4 space-y-2">
            <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Examples
            </div>
            <ul class="space-y-2">
              <%!-- credo:disable-for-next-line Emisar.Checks.NoIslandContainers — earned artifact frame (example args JSON), pending code_panel migration --%>
              <li
                :for={ex <- action_examples(@action)}
                class="rounded-lg bg-black/40 p-3 ring-1 ring-white/[0.08]"
              >
                <div :if={ex["description"]} class="text-xs text-zinc-400">{ex["description"]}</div>
                <pre
                  tabindex="0"
                  aria-label="Example arguments"
                  class="mt-1 overflow-x-auto font-mono text-[11px] leading-5 text-zinc-200"
                ><%= example_args_json(ex) %></pre>
              </li>
            </ul>
          </div>

          <%!-- The action's facts as the NAKED meta row (the detail grammar),
               not a boxed strip. --%>
          <div class="mt-8 grid grid-cols-2 gap-x-10 gap-y-8 sm:flex sm:flex-wrap sm:items-start sm:gap-x-14">
            <%!-- wrap: the pill carries the severity lexicon in a <.tooltip>, and
             truncation would clip both the bubble and the pill (§7.35). --%>
            <.meta_field label="Risk" wrap>
              <.risk_pill id={"run-new-#{@action.action_id}-risk"} risk={@action.risk} />
            </.meta_field>
            <.meta_field label="Kind">
              <span class="text-zinc-200">{@action.kind}</span>
            </.meta_field>
            <.meta_field label="Pack">
              <span class="truncate text-zinc-200">{@action.pack_id || "—"}</span>
            </.meta_field>
          </div>
        </section>

        <%!-- Offline-runner notice. The runner is only looked up on the
             connected render, so this stays quiet on the dead pass. We
             let the operator dispatch anyway (a direct/bookmarked link is
             a fine reason to queue) — runner_detail disables Run instead,
             but here we warn it'll queue rather than block. --%>
        <.offline_notice
          :if={dispatch_would_queue?(@readiness)}
          severity={:info}
          title="Runner offline"
        >
          {@runner.name} isn't connected right now. You can still dispatch — the run queues as
          <span class="font-mono text-zinc-300">pending</span>
          and executes when the runner reconnects.
        </.offline_notice>

        <%!-- Signed-only runner — the portal is locked out. This actionable
             interruption takes precedence over the offline posture note and
             replaces the Dispatch button below. --%>
        <.event_block
          :if={signature_blocked?(@readiness)}
          icon="hero-shield-check"
          tone={:brand}
          title="Signed dispatch only"
        >
          <:body>
            {@runner.name} verifies a client signature on every run and refuses unsigned ones, so
            the portal can't dispatch to it. Run this action from an MCP client configured with the
            runner's signing key.
            <.doc_link href={~p"/docs/signed-dispatch"}>Signed dispatch docs</.doc_link>
          </:body>
        </.event_block>

        <%!-- The form — primary surface. Reason is always required;
             args render only when the action declares any, so the
             "Arguments" header (and its "no arguments" microcopy)
             don't waste space on zero-arg actions like `linux.uptime`.
             Same progressive-disclosure rule as elsewhere: don't show
             a section just to tell the operator there's nothing in
             it. --%>
        <section>
          <.section_header title={if(@args_schema == [], do: "Dispatch", else: "Arguments")} />
          <.simple_form
            for={@form}
            id="dispatch_form"
            phx-submit="dispatch"
            phx-change="validate"
          >
            <.arg_input :for={arg <- @args_schema} arg={arg} form={@form} />

            <%!-- Mark-optional-only: Reason is required, so it carries no marker;
                 the audit-transparency note moves to a hint below the field.
                 Dispatchers only — an editable form above a "you can't run
                 this" note handed viewers dead inputs. --%>
            <div :if={@can_dispatch?}>
              <.input
                name="reason"
                value={@reason}
                type="textarea"
                label="Reason"
                errors={List.wrap(@reason_error)}
                rows="2"
                required={true}
                placeholder="Why are you running this action?"
              />
              <p class="mt-1 text-xs text-zinc-400">Logged to the audit trail.</p>
            </div>

            <:actions>
              <%!-- The last glance binds action + host: the button names the
                   TARGET, so a mis-aimed dispatch is caught at the click. --%>
              <.button
                :if={@can_dispatch? and portal_dispatchable?(@readiness)}
                phx-disable-with="Dispatching..."
                data-confirm={dispatch_confirm(@action, @runner, @runner_id, @args_schema, @form)}
              >
                Dispatch to {(@runner && @runner.name) || "runner"}
                <span aria-hidden="true">→</span>
              </.button>
              <%!-- Signed-only runner — the run would be refused, so there's no
                   Dispatch button; the quiet fact points at the MCP client. --%>
              <p
                :if={@can_dispatch? and signature_blocked?(@readiness)}
                class="text-sm text-zinc-400"
              >
                This runner only runs signed dispatches — run it from your MCP client.
              </p>
              <%!-- Disabled runner — also buttonless, but the remedy is on the
                   runner's own page rather than in an MCP client. --%>
              <p
                :if={@can_dispatch? and dispatch_disabled?(@readiness)}
                class="text-sm text-zinc-400"
              >
                This runner is disabled — enable it on the runner's page before dispatching.
              </p>
              <%!-- Viewers can reach this page but can't dispatch; the
                   handler also gates (IL-15) — this hides the dead button. --%>
              <p :if={not @can_dispatch?} class="text-sm text-zinc-400">
                Your role can't dispatch runs. Ask an operator, admin, or owner to run this.
              </p>
            </:actions>
          </.simple_form>
        </section>
      </div>
    </.dashboard_shell>
    """
  end

  # Maps a runner action arg's declared type to the form input type + an
  # optional hint shown beneath the field. Fallback is a plain text
  # input with no hint, so adding a new arg type is a one-line entry
  # here rather than a new cond branch.
  @input_type_for %{
    "boolean" => {"checkbox", nil},
    "integer" => {"number", nil},
    "number" => {"number", nil},
    "string_array" => {"text", "Comma-separated."},
    "integer_array" => {"text", "Comma-separated."},
    "duration" => {"text", "Go duration (e.g. 30s, 5m, 2h)."}
  }
  defp input_type_for(type), do: Map.get(@input_type_for, type, {"text", nil})

  # Mark-optional-only: a required arg shows its bare name, an optional one is
  # tagged "(optional)" so the operator can tell what they may leave blank.
  defp arg_label(%{"required" => true, "name" => name}), do: name
  defp arg_label(%{"name" => name}), do: "#{name} (optional)"

  attr :arg, :map, required: true
  attr :form, :any, required: true

  defp arg_input(assigns) do
    type = assigns.arg["type"]

    {input_type, hint} = input_type_for(type)
    assigns = assign(assigns, input_type: input_type, hint: hint)

    ~H"""
    <div>
      <.input
        field={@form[@arg["name"]]}
        type={@input_type}
        label={arg_label(@arg)}
        required={@arg["required"]}
        placeholder={@arg["description"]}
      />
      <p :if={@hint} class="mt-1 text-xs text-zinc-400">{@hint}</p>
    </div>
    """
  end

  # -- form ------------------------------------------------------------
  #
  # The inputs are dynamic — one per declared action arg — so the form is
  # backed by the raw string param map (binary keys), not an Ecto schema
  # or schemaless changeset: the arg names are runtime strings, and
  # turning them into the atom keys a changeset needs would mean
  # `String.to_atom/1` on runner/pack-advertised input (IL-14). Instead we
  # hand `to_form` the params plus an `errors` keyword keyed by those same
  # binary arg names; `<.input field={@form[name]}>` then renders each
  # error inline under its field with the rose border, exactly as a
  # changeset-backed form would. (`<.input>` shows an error only for a
  # field the client actually submitted/touched — `used_input?/1` — so an
  # untouched field stays quiet until submit.)

  defp assign_form(socket, params, errors \\ []) do
    assign(socket, :form, to_form(params, as: "args", errors: errors))
  end

  # -- arg errors ------------------------------------------------------
  #
  # `Emisar.ActionContract` owns the defaults, coercion, and validation; the
  # only web-side translation is turning its issues into the `{msg, opts}`
  # tuples `<.input field={@form[name]}>` renders inline (rose border + message
  # under the field). Every failing arg comes back, not just the first, so the
  # operator sees all of them in one pass.

  # Field errors for `phx-change` validation — same cast, but we only want the
  # error list (the typed args are recomputed on submit).
  defp arg_errors(raw_args, action) do
    case ActionContract.cast_form(raw_args, action) do
      {:ok, _args} -> []
      {:error, issues} -> Enum.map(issues, &field_error/1)
    end
  end

  # The domain's required message reads bare ("is required"), so it takes the
  # arg name here — the field label is above the input, the error below it.
  defp field_error(%{arg: arg, code: "required"}), do: {arg, {"#{arg} is required", []}}
  defp field_error(%{arg: arg, message: message}), do: {arg, {message, []}}

  # `examples` is a packspec field — list of `{description, args}` maps.
  # Defensive: any shape that isn't a list is a no-op render. Empty
  # examples (no args AND no description) are dropped — for a zero-arg
  # action like `linux.uptime` they'd render a useless "{}" card.
  defp action_examples(%{examples: list}) when is_list(list),
    do: Enum.filter(list, &meaningful_example?/1)

  defp action_examples(_), do: []

  defp meaningful_example?(%{"args" => args}) when is_map(args) and map_size(args) > 0, do: true
  defp meaningful_example?(%{"description" => d}) when is_binary(d) and d != "", do: true
  defp meaningful_example?(_), do: false

  # Pretty-print the example args. Keep it compact — these go in a
  # tight info card, not a sprawling pre.
  defp example_args_json(%{"args" => args}) when is_map(args),
    do: Jason.encode!(args, pretty: true)

  defp example_args_json(_), do: "{}"
end

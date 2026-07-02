defmodule EmisarWeb.RunNewLive do
  use EmisarWeb, :live_view
  alias Emisar.{Catalog, Runners, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"runner_id" => runner_id, "action_id" => action_id}, _session, socket) do
    case Catalog.fetch_action_by_id(action_id, runner_id, socket.assigns.current_subject) do
      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Action not found.")
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
         |> assign(:args_schema, args_schema)
         |> assign_form(initial_args(args_schema))
         |> assign(:reason, "")
         |> assign(
           :can_dispatch?,
           Runs.subject_can_dispatch_run?(socket.assigns.current_subject)
         )}
    end
  end

  defp lookup_runner(runner_id, socket) do
    case Runners.fetch_runner_by_id(runner_id, socket.assigns.current_subject) do
      {:ok, r} -> r
      {:error, :not_found} -> nil
    end
  end

  # Strict boolean (never nil) so `not signed_only?(@runner)` in the template is
  # safe on the dead render, where @runner is still nil.
  defp signed_only?(%{enforce_signatures: true}), do: true
  defp signed_only?(_), do: false

  # Show the "it'll queue" offline notice only for an offline runner the portal
  # can still reach — a signed-only runner is blocked, not queued, so its own
  # notice (below) carries the state instead. Strict boolean, nil-safe.
  defp offline_notice?(%{online?: false} = runner), do: not signed_only?(runner)
  defp offline_notice?(_), do: false

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

    {:noreply,
     socket
     |> assign_form(args, arg_errors(args, socket.assigns.args_schema))
     |> assign(:reason, params["reason"] || socket.assigns.reason)}
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

    if String.trim(reason) == "" do
      {:noreply,
       socket
       |> assign(:reason, reason)
       |> put_flash(:error, "Reason is required — describe why you are running this action.")}
    else
      do_dispatch_with_reason(socket, raw_args, reason)
    end
  end

  defp do_dispatch_with_reason(socket, raw_args, reason) do
    case coerce_args(raw_args, socket.assigns.args_schema) do
      # Bad/missing args render inline under the offending fields (rose
      # border) via the form's per-arg errors — not a flash banner.
      {:error, errors} ->
        {:noreply, assign_form(socket, raw_args, errors)}

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
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
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
      <:actions>
        <.risk_pill risk={@action.risk} />
      </:actions>

      <div class="space-y-6">
        <%!-- Action context — what you're about to do. Description
             prose + meta strip (risk/kind/pack). Replaces the
             stranded right-side info card. --%>
        <.panel :if={@action.description && @action.description != ""} title={@action.title}>
          <p class="text-sm leading-relaxed text-zinc-400">{@action.description}</p>

          <%!-- Pack-provided examples — short canonical invocations
               with sample args. Big UX win when an operator has the
               form open and is wondering "what does a real call look
               like?". Only renders when the pack ships examples. --%>
          <div :if={action_examples(@action) != []} class="mt-4 space-y-2">
            <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
              Examples
            </div>
            <ul class="space-y-2">
              <li
                :for={ex <- action_examples(@action)}
                class="rounded-lg border border-zinc-800 bg-black/40 p-3"
              >
                <div :if={ex["description"]} class="text-xs text-zinc-400">{ex["description"]}</div>
                <pre class="mt-1 overflow-x-auto font-mono text-[11px] leading-5 text-zinc-200"><%= example_args_json(ex) %></pre>
              </li>
            </ul>
          </div>
        </.panel>

        <.meta_strip cols={3}>
          <.meta_field label="Risk">
            <.risk_pill risk={@action.risk} />
          </.meta_field>
          <.meta_field label="Kind">
            <span class="text-zinc-200">{@action.kind}</span>
          </.meta_field>
          <.meta_field label="Pack">
            <span class="truncate text-zinc-200">{@action.pack_id || "—"}</span>
          </.meta_field>
        </.meta_strip>

        <%!-- Side-effects warning — loud when this action will mutate
             real state. Empty list (read-only action) hides it. --%>
        <.callout
          :if={@action.side_effects && @action.side_effects != []}
          tone={:amber}
          title="Side effects"
        >
          <ul class="space-y-1">
            <li :for={effect <- @action.side_effects} class="flex items-start gap-2">
              <span class="mt-2 h-1 w-1 flex-none rounded-full bg-amber-300"></span>
              <span>{effect}</span>
            </li>
          </ul>
        </.callout>

        <%!-- Offline-runner notice. The runner is only looked up on the
             connected render, so this stays quiet on the dead pass. We
             let the operator dispatch anyway (a direct/bookmarked link is
             a fine reason to queue) — runner_detail disables Run instead,
             but here we warn it'll queue rather than block. --%>
        <.offline_notice
          :if={offline_notice?(@runner)}
          severity={:info}
          title="Runner offline"
        >
          {@runner.name} isn't connected right now. You can still dispatch — the run queues as
          <span class="font-mono text-zinc-300">pending</span>
          and executes when the runner reconnects.
        </.offline_notice>

        <%!-- Signed-only runner — the portal is locked out. Takes precedence over
             the offline notice above (whose "you can still dispatch" copy would
             contradict this), and replaces the Dispatch button below. --%>
        <.callout
          :if={signed_only?(@runner)}
          tone={:brand}
          icon="hero-shield-check"
          title="Signed dispatch only"
        >
          {@runner.name} verifies a client signature on every run and refuses unsigned ones, so
          the portal can't dispatch to it. Run this action from an MCP client configured with the
          runner's signing key.
        </.callout>

        <%!-- The form — primary surface. Reason is always required;
             args render only when the action declares any, so the
             "Arguments" header (and its "no arguments" microcopy)
             don't waste space on zero-arg actions like `linux.uptime`.
             Same progressive-disclosure rule as elsewhere: don't show
             a section just to tell the operator there's nothing in
             it. --%>
        <.panel title={if(@args_schema == [], do: "Dispatch", else: "Arguments")}>
          <.simple_form
            for={@form}
            id="dispatch_form"
            phx-submit="dispatch"
            phx-change="validate"
          >
            <.arg_input :for={arg <- @args_schema} arg={arg} form={@form} />

            <.input
              name="reason"
              value={@reason}
              type="textarea"
              label="Reason (required — logged in audit)"
              rows="2"
              required={true}
              placeholder="Why are you running this action?"
            />

            <:actions>
              <.button
                :if={@can_dispatch? and not signed_only?(@runner)}
                class="w-full"
                phx-disable-with="Dispatching..."
                data-confirm={dispatch_confirm(@action, @runner, @runner_id, @args_schema, @form)}
              >
                Dispatch to runner <span aria-hidden="true">→</span>
              </.button>
              <%!-- Signed-only runner — the run would be refused, so there's no
                   Dispatch button; point the operator at their MCP client. --%>
              <.callout
                :if={@can_dispatch? and signed_only?(@runner)}
                tone={:neutral}
                icon={false}
                class="text-center"
              >
                This runner only runs signed dispatches — run it from your MCP client.
              </.callout>
              <%!-- Viewers can reach this page but can't dispatch; the
                   handler also gates (IL-15) — this hides the dead button. --%>
              <.callout :if={not @can_dispatch?} tone={:neutral} icon={false} class="text-center">
                Your role can't dispatch runs. Ask an operator, admin, or owner to run this.
              </.callout>
            </:actions>
          </.simple_form>
        </.panel>
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
    "bool" => {"checkbox", nil},
    "integer" => {"number", nil},
    "number" => {"number", nil},
    "string_array" => {"text", "Comma-separated."},
    "integer_array" => {"text", "Comma-separated."},
    "duration" => {"text", "Go duration (e.g. 30s, 5m, 2h)."}
  }
  defp input_type_for(type), do: Map.get(@input_type_for, type, {"text", nil})

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
        label={@arg["name"]}
        required={@arg["required"]}
        placeholder={@arg["description"]}
      />
      <p :if={@hint} class="mt-1 text-xs text-zinc-500">{@hint}</p>
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

  # -- initial values --------------------------------------------------

  defp initial_args(schema) do
    Enum.into(schema, %{}, fn arg ->
      {arg["name"], initial_value(arg["type"], arg["default"])}
    end)
  end

  defp initial_value(type, default) when type in ~w(string_array integer_array) do
    case default do
      list when is_list(list) -> Enum.map_join(list, ", ", &to_string/1)
      nil -> ""
      other -> to_string(other)
    end
  end

  defp initial_value(type, default) when type in ~w(boolean bool) do
    case default do
      true -> "true"
      false -> "false"
      nil -> "false"
      _ -> "false"
    end
  end

  defp initial_value(_, nil), do: ""
  defp initial_value(_, default), do: to_string(default)

  # -- coercion --------------------------------------------------------
  #
  # The form always submits string values. We parse them into the shapes
  # the runner's validator expects, per the declared arg type. Missing
  # required args become an error here so we don't dispatch a bad run.
  #
  # Errors come back keyed by arg name as `{msg, opts}` tuples — the exact
  # shape `<.input field={@form[name]}>` renders inline (rose border +
  # message under the field). We collect *every* bad arg, not just the
  # first, so the operator sees all of them in one pass.

  defp coerce_args(raw, schema) do
    {ok, errors} =
      Enum.reduce(schema, {%{}, []}, fn arg, {acc, errs} ->
        name = arg["name"]

        case coerce_one(arg, Map.get(raw, name)) do
          :skip -> {acc, errs}
          {:ok, parsed} -> {Map.put(acc, name, parsed), errs}
          {:error, reason} -> {acc, [{name, {reason, []}} | errs]}
        end
      end)

    if errors == [], do: {:ok, ok}, else: {:error, Enum.reverse(errors)}
  end

  # Field errors for `phx-change` validation — same coercion, but we only
  # want the error list (the coerced values are recomputed on submit).
  defp arg_errors(raw, schema) do
    case coerce_args(raw, schema) do
      {:ok, _} -> []
      {:error, errors} -> errors
    end
  end

  # Missing or blank optional → skip. Missing required → error.
  defp coerce_one(%{"required" => true, "name" => name}, v) when v in [nil, ""] do
    {:error, "#{name} is required"}
  end

  defp coerce_one(_arg, v) when v in [nil, ""], do: :skip

  defp coerce_one(%{"type" => t}, v) when t in ~w(string path duration) do
    {:ok, v}
  end

  defp coerce_one(%{"type" => t}, v) when t in ~w(boolean bool) do
    {:ok, v in ["true", "on", true]}
  end

  defp coerce_one(%{"type" => "integer"}, v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "not an integer"}
    end
  end

  defp coerce_one(%{"type" => "number"}, v) do
    case Float.parse(String.trim(v)) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "not a number"}
    end
  end

  defp coerce_one(%{"type" => "string_array"}, v) do
    {:ok, split_csv(v)}
  end

  defp coerce_one(%{"type" => "integer_array"}, v) do
    parts = split_csv(v)

    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case Integer.parse(part) do
        {n, ""} -> {:cont, {:ok, [n | acc]}}
        _ -> {:halt, {:error, "#{inspect(part)} is not an integer"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp coerce_one(_arg, v), do: {:ok, v}

  defp split_csv(v) when is_binary(v) do
    v
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

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

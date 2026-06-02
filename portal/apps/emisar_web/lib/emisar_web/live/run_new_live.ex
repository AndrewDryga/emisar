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
         |> push_navigate(to: ~p"/app/runners/#{runner_id}")}

      {:ok, action} ->
        args_schema = action.args_schema["args"] || []

        runner =
          case Runners.fetch_runner_by_id(runner_id, socket.assigns.current_subject) do
            {:ok, r} -> r
            {:error, :not_found} -> nil
          end

        {:ok,
         socket
         |> assign(:page_title, "Run #{action.action_id}")
         |> assign(:action, action)
         |> assign(:runner_id, runner_id)
         |> assign(:runner, runner)
         |> assign(:args_schema, args_schema)
         |> assign(:form, to_form(initial_args(args_schema), as: "args"))
         |> assign(:reason, "")}
    end
  end

  def handle_event("validate", params, socket) do
    # Actions with no arg schema render only the `reason` field, so the
    # phx-change payload won't contain `"args"`. Default to the existing
    # form so the empty-args case doesn't FunctionClauseError.
    args = Map.get(params, "args", socket.assigns.form.params)

    {:noreply,
     socket
     |> assign(:form, to_form(args, as: "args"))
     |> assign(:reason, params["reason"] || socket.assigns.reason)}
  end

  def handle_event("dispatch", params, socket) do
    Permissions.gated(socket, :dispatch_run, fn s -> do_dispatch(s, params) end)
  end

  defp do_dispatch(socket, params) do
    raw_args = params["args"] || %{}
    reason = params["reason"] || ""

    cond do
      String.trim(reason) == "" ->
        {:noreply,
         socket
         |> assign(:reason, reason)
         |> put_flash(:error, "Reason is required — describe why you are running this action.")}

      true ->
        do_dispatch_with_reason(socket, raw_args, reason)
    end
  end

  defp do_dispatch_with_reason(socket, raw_args, reason) do
    case coerce_args(raw_args, socket.assigns.args_schema) do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid: #{msg}")}

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
            {:noreply, push_navigate(socket, to: ~p"/app/runs/#{run.id}")}

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

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, "Invalid: #{humanize_errors(changeset)}")}
        end
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      pending_approvals_count={@pending_approvals_count}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runs}
    >
      <:title>
        <.back_link navigate={~p"/app/runners"}>Runners</.back_link>
        <.back_link navigate={~p"/app/runners/#{@runner_id}"}>
          {(@runner && @runner.name) || "Runner"}
        </.back_link>
        Run <span class="font-mono text-base">{@action.action_id}</span>
      </:title>
      <:actions>
        <.risk_pill risk={@action.risk} />
      </:actions>

      <div class="mx-auto max-w-3xl space-y-6">
        <%!-- Action context — what you're about to do. Description
             prose + meta strip (risk/kind/pack). Replaces the
             stranded right-side info card. --%>
        <section
          :if={@action.description && @action.description != ""}
          class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5"
        >
          <h2 :if={@action.title} class="text-sm font-semibold text-zinc-100">{@action.title}</h2>
          <p class="mt-1 text-sm leading-relaxed text-zinc-400">{@action.description}</p>

          <%!-- Pack-provided examples — short canonical invocations
               with sample args. Big UX win when an operator has the
               form open and is wondering "what does a real call look
               like?". Only renders when the pack ships examples. --%>
          <div :if={action_examples(@action) != []} class="mt-4 space-y-2">
            <div class="text-[10px] font-semibold uppercase tracking-wider text-zinc-500">
              Examples
            </div>
            <ul class="space-y-2">
              <li
                :for={ex <- action_examples(@action)}
                class="rounded-lg border border-zinc-900 bg-black/40 p-3"
              >
                <div :if={ex["description"]} class="text-xs text-zinc-400">{ex["description"]}</div>
                <pre class="mt-1 overflow-x-auto font-mono text-[11px] leading-5 text-zinc-200"><%= example_args_json(ex) %></pre>
              </li>
            </ul>
          </div>
        </section>

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
        <section
          :if={@action.side_effects && @action.side_effects != []}
          class="rounded-xl border border-amber-500/30 bg-amber-500/[0.04] p-4"
        >
          <h3 class="flex items-center gap-2 text-xs font-semibold uppercase tracking-wider text-amber-200/80">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4 text-amber-300" /> Side effects
          </h3>
          <ul class="mt-2 space-y-1 text-sm text-amber-100/90">
            <li :for={effect <- @action.side_effects} class="flex items-start gap-2">
              <span class="mt-2 h-1 w-1 flex-none rounded-full bg-amber-300"></span>
              <span>{effect}</span>
            </li>
          </ul>
        </section>

        <%!-- The form — primary surface. Reason is always required;
             args render only when the action declares any, so the
             "Arguments" header (and its "no arguments" microcopy)
             don't waste space on zero-arg actions like `linux.uptime`.
             Same progressive-disclosure rule as elsewhere: don't show
             a section just to tell the operator there's nothing in
             it. --%>
        <section class="rounded-xl border border-zinc-900 bg-zinc-950/40 p-5">
          <h2 class="text-sm font-semibold text-zinc-100">
            {if(@args_schema == [], do: "Dispatch", else: "Arguments")}
          </h2>

          <.simple_form
            for={@form}
            id="dispatch_form"
            phx-submit="dispatch"
            phx-change="validate"
            class="mt-4"
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
              <.button class="w-full" phx-disable-with="Dispatching...">
                Dispatch to runner <span aria-hidden="true">→</span>
              </.button>
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

  defp coerce_args(raw, schema) do
    Enum.reduce_while(schema, {:ok, %{}}, fn arg, {:ok, acc} ->
      name = arg["name"]
      value = Map.get(raw, name)

      case coerce_one(arg, value) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, name, parsed)}}
        {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
      end
    end)
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
  # Defensive: any shape that isn't a list is a no-op render.
  defp action_examples(%{examples: list}) when is_list(list), do: list
  defp action_examples(_), do: []

  # Pretty-print the example args. Keep it compact — these go in a
  # tight info card, not a sprawling pre.
  defp example_args_json(%{"args" => args}) when is_map(args),
    do: Jason.encode!(args, pretty: true)

  defp example_args_json(_), do: "{}"
end

defmodule EmisarWeb.RunNewLive do
  use EmisarWeb, :live_view

  alias Emisar.{Catalog, Runs}
  alias EmisarWeb.Permissions

  def mount(%{"runner_id" => runner_id, "action_id" => action_id}, _session, socket) do
    account_id = socket.assigns.current_account.id

    case Catalog.get_action(account_id, runner_id, action_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Action not found.")
         |> push_navigate(to: ~p"/app/runners/#{runner_id}")}

      action ->
        args_schema = action.args_schema["args"] || []

        {:ok,
         socket
         |> assign(:page_title, "Run #{action.action_id}")
         |> assign(:action, action)
         |> assign(:runner_id, runner_id)
         |> assign(:args_schema, args_schema)
         |> assign(:form, to_form(initial_args(args_schema), as: "args"))
         |> assign(:reason, "")}
    end
  end

  def handle_event("validate", %{"args" => args} = params, socket) do
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
          requested_by_id: socket.assigns.current_user.id
        }

        case Runs.dispatch(socket.assigns.current_account.id, attrs) do
          {:ok, _status, run} ->
            {:noreply, push_navigate(socket, to: ~p"/app/runs/#{run.id}")}

          {:error, :denied_by_policy, reason} ->
            {:noreply, put_flash(socket, :error, "Denied by policy: #{reason}")}

          {:error, :runner_not_found} ->
            {:noreply, put_flash(socket, :error, "Runner not found in this account.")}

          {:error, :runner_required} ->
            {:noreply, put_flash(socket, :error, "Runner is required.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, "Invalid: #{inspect(changeset.errors)}")}
        end
    end
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runs}
    >
      <:title>Run <span class="font-mono text-base">{@action.action_id}</span></:title>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card class="lg:col-span-2">
          <.section_header title="Arguments" />

          <.simple_form for={@form} id="dispatch_form" phx-submit="dispatch" phx-change="validate">
            <.arg_input :for={arg <- @args_schema} arg={arg} form={@form} />

            <.input
              name="reason"
              value={@reason}
              type="textarea"
              label="Reason (required — logged in audit)"
              rows="2"
              required={true}
            />

            <:actions>
              <.button class="w-full" phx-disable-with="Dispatching...">
                Dispatch to runner <span aria-hidden="true">→</span>
              </.button>
            </:actions>
          </.simple_form>
        </.card>

        <.card>
          <.section_header title={@action.title} />
          <p class="mt-2 text-sm text-zinc-400">{@action.description}</p>

          <dl class="mt-6 space-y-1 text-xs">
            <.kv label="Risk"><.risk_pill risk={@action.risk} /></.kv>
            <.kv label="Kind">{@action.kind}</.kv>
            <.kv label="Pack">{@action.pack_id || "—"}</.kv>
          </dl>

          <%= if @action.side_effects && @action.side_effects != [] do %>
            <div class="mt-6">
              <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Side effects</h3>
              <ul class="mt-2 space-y-1 text-xs text-zinc-400">
                <li :for={effect <- @action.side_effects}>• {effect}</li>
              </ul>
            </div>
          <% end %>
        </.card>
      </div>
    </.dashboard_shell>
    """
  end

  attr :arg, :map, required: true
  attr :form, :any, required: true

  defp arg_input(assigns) do
    type = assigns.arg["type"]

    {input_type, hint} =
      cond do
        type in ~w(boolean bool) -> {"checkbox", nil}
        type in ~w(integer number) -> {"number", nil}
        type in ~w(string_array integer_array) -> {"text", "Comma-separated."}
        type == "duration" -> {"text", "Go duration (e.g. 30s, 5m, 2h)."}
        true -> {"text", nil}
      end

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
end

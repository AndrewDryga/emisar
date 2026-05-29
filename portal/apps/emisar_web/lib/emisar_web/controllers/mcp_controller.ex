defmodule EmisarWeb.McpController do
  @moduledoc """
  MCP / LLM tool surface. Authenticates via API key in the
  `Authorization: Bearer <key>` header.

  Endpoints:

    * `GET  /api/mcp/tools` — return the list of action descriptors the
      caller is allowed to invoke, formatted as MCP tool definitions.
    * `POST /api/mcp/tools/:action_id` — dispatch a run. Defaults to
      fire-and-forget; pass `?wait=15s` (or any `<=60s`) to long-poll
      until the run reaches a terminal state and have the result body
      returned synchronously.
    * `GET  /api/mcp/runs/:id` — fetch the current state of a run,
      including stdout / stderr / structured output collected so far.
  """

  use EmisarWeb, :controller

  alias Emisar.{ApiKeys, Catalog, Runs}

  plug :authenticate
  plug :require_scope, "actions:read" when action in [:list_tools, :get_run]
  plug :require_scope, "actions:execute" when action in [:run_tool]

  # Hard cap on how long a synchronous call can block the controller
  # thread, irrespective of what the client requested.
  @max_wait_ms 60_000
  @poll_interval_ms 200

  # GET /api/mcp/tools
  def list_tools(conn, _params) do
    actions = Catalog.list_actions_for_account(conn.assigns.api_key.account_id)
    json(conn, %{tools: Enum.map(actions, &mcp_tool_from_action/1)})
  end

  # POST /api/mcp/tools/:action_id
  def run_tool(conn, %{"action_id" => action_id} = params) do
    api_key = conn.assigns.api_key
    runner_id = params["runner_id"] || pick_agent(api_key, action_id)

    cond do
      is_nil(runner_id) ->
        conn |> put_status(:bad_request) |> json(%{error: "runner_required"})

      not runner_allowed_by_key?(api_key, runner_id) ->
        conn |> put_status(:forbidden) |> json(%{error: "runner_not_in_key_filter"})

      true ->
        attrs = %{
          action_id: action_id,
          runner_id: runner_id,
          args: params["args"] || %{},
          opts: params["opts"] || %{},
          # No default reason — LLMs/scripts must supply one. The runner
          # and Runs.dispatch both reject empty reasons.
          reason: params["reason"],
          source: "mcp",
          api_key_id: api_key.id
        }

        case Runs.dispatch(api_key.account_id, attrs) do
          {:ok, status, run} ->
            handle_dispatched(conn, run, status, params["wait"])

          {:error, :denied_by_policy, reason} ->
            conn |> put_status(:forbidden) |> json(%{error: "policy_denied", reason: reason})

          {:error, :runner_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "runner_not_found"})

          {:error, :runner_required} ->
            conn |> put_status(:bad_request) |> json(%{error: "runner_required"})

          {:error, :reason_required} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "reason_required",
              message:
                "Every action call must include a non-empty `reason` field describing why the action is being run."
            })

          {:error, :action_not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "action_not_found"})

          {:error, :action_required} ->
            conn |> put_status(:bad_request) |> json(%{error: "action_required"})

          {:error, changeset} ->
            conn |> put_status(:bad_request) |> json(%{error: "invalid", details: errors(changeset)})
        end
    end
  end

  # GET /api/mcp/runs/:id
  def get_run(conn, %{"id" => id}) do
    case Runs.get_run(conn.assigns.api_key.account_id, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      run ->
        json(conn, full_run_payload(run))
    end
  end

  # -- Dispatch helpers ------------------------------------------------

  # When the operator asks the cloud to wait, we poll the DB until the
  # run is terminal (or the deadline expires). Polling is the simplest
  # working version; once we move to per-run PubSub we can swap this for
  # a `subscribe + receive` so we wake up the instant the result lands.
  defp handle_dispatched(conn, run, :pending_approval, _wait) do
    conn
    |> put_status(:accepted)
    |> json(%{run_id: run.id, status: "pending_approval", waiting_on: "approval"})
  end

  defp handle_dispatched(conn, run, status, nil) do
    conn |> put_status(:accepted) |> json(%{run_id: run.id, status: status})
  end

  defp handle_dispatched(conn, run, _status, wait) do
    case parse_wait(wait) do
      {:ok, 0} ->
        conn |> put_status(:accepted) |> json(%{run_id: run.id, status: "running"})

      {:ok, ms} ->
        deadline = System.monotonic_time(:millisecond) + ms

        case poll_to_terminal(run.account_id, run.id, deadline) do
          {:terminal, final_run} ->
            json(conn, full_run_payload(final_run))

          :timeout ->
            current = Runs.get_run(run.account_id, run.id) || run

            conn
            |> put_status(:accepted)
            |> json(%{
              run_id: run.id,
              status: current.status,
              waiting: "timeout",
              tip: "GET /api/mcp/runs/#{run.id} to keep polling"
            })
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_wait", expected: "duration string e.g. '15s', max 60s"})
    end
  end

  defp poll_to_terminal(account_id, run_id, deadline) do
    case Runs.get_run(account_id, run_id) do
      nil ->
        :timeout

      %{status: status} = run when status in ~w(success failed error validation_failed unknown_action cancelled timed_out denied) ->
        {:terminal, run}

      _ ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          :timeout
        else
          Process.sleep(min(@poll_interval_ms, max(deadline - now, 1)))
          poll_to_terminal(account_id, run_id, deadline)
        end
    end
  end

  # Accepts "15s", "1m", "500ms"; clamps to @max_wait_ms.
  defp parse_wait(s) when is_binary(s) do
    case Regex.run(~r/^(\d+)(ms|s|m)?$/, s) do
      [_, num, unit] ->
        ms = String.to_integer(num) * unit_to_ms(unit)
        {:ok, min(ms, @max_wait_ms)}

      [_, num] ->
        ms = String.to_integer(num) * 1000
        {:ok, min(ms, @max_wait_ms)}

      _ ->
        :error
    end
  end

  defp parse_wait(_), do: :error

  defp unit_to_ms(""), do: 1000
  defp unit_to_ms("ms"), do: 1
  defp unit_to_ms("s"), do: 1000
  defp unit_to_ms("m"), do: 60_000

  # -- Run payload (incl. output) -------------------------------------

  # Streams a bounded slice of stdout/stderr by reading the
  # `action_run_events` rows the runner socket persisted. Defaults are
  # generous enough for LLM tool-use round trips (~64 KiB each) but
  # bounded so a noisy action can't blow up the controller process.
  @stdout_cap 65_536
  @stderr_cap 65_536

  defp full_run_payload(run) do
    events = Runs.list_events(run.id, limit: 5_000)

    {stdout, stderr} = collect_streams(events)

    %{
      id: run.id,
      status: run.status,
      action_id: run.action_id,
      runner_id: run.runner_id,
      request_id: run.request_id,
      exit_code: run.exit_code,
      duration_ms: run.duration_ms,
      started_at: run.started_at,
      finished_at: run.finished_at,
      reason: run.reason_text,
      error_message: run.error_message,
      stdout: truncate(stdout, @stdout_cap),
      stderr: truncate(stderr, @stderr_cap),
      stdout_truncated: byte_size(stdout) > @stdout_cap,
      stderr_truncated: byte_size(stderr) > @stderr_cap,
      stdout_sha256: run.stdout_sha256,
      stderr_sha256: run.stderr_sha256,
      stdout_bytes: run.stdout_bytes,
      stderr_bytes: run.stderr_bytes,
      policy: %{
        decision: run.policy_decision,
        reason: run.policy_reason,
        rules: run.matched_rules || []
      }
    }
  end

  defp collect_streams(events) do
    Enum.reduce(events, {"", ""}, fn ev, {out, err} ->
      chunk = get_chunk(ev)
      stream = ev.stream || (ev.payload && ev.payload["stream"])

      case stream do
        "stderr" -> {out, err <> chunk}
        _ -> {out <> chunk, err}
      end
    end)
  end

  defp get_chunk(%{payload: %{"chunk" => c}}) when is_binary(c), do: c
  defp get_chunk(_), do: ""

  defp truncate(s, n) when byte_size(s) <= n, do: s
  defp truncate(s, n), do: binary_part(s, byte_size(s) - n, n)

  # -- Helpers --------------------------------------------------------

  # Many LLMs use only the tool description for safety reasoning, so
  # surface side_effects inline. The runner advertises them; without
  # this, an MCP client sees just the title and may dispatch high-side-
  # effect actions thinking they're read-only.
  defp full_description(action) do
    base = action.description || action.title
    fx = action.side_effects || []

    case fx do
      [] ->
        base

      list ->
        bullets = Enum.map_join(list, "\n", &("- " <> &1))
        base <> "\n\nSide effects:\n" <> bullets
    end
  end

  defp mcp_tool_from_action(action) do
    arg_properties =
      Enum.into(action.args_schema["args"] || [], %{}, fn arg ->
        {arg["name"],
         %{
           type: arg["type"],
           description: arg["description"]
         }}
      end)

    arg_required =
      (action.args_schema["args"] || [])
      |> Enum.filter(& &1["required"])
      |> Enum.map(& &1["name"])

    %{
      name: action.action_id,
      description: full_description(action),
      risk: action.risk,
      kind: action.kind,
      side_effects: action.side_effects || [],
      inputSchema: %{
        type: "object",
        properties:
          Map.put(arg_properties, "reason", %{
            type: "string",
            description:
              "Why you are running this action — a short freeform sentence. Logged in the immutable audit trail. Required."
          }),
        required: ["reason" | arg_required]
      }
    }
  end

  defp pick_agent(%{account_id: account_id, runner_filter: filter}, action_id) do
    Catalog.list_actions_for_account(account_id)
    |> Enum.find(fn a ->
      a.action_id == action_id and (filter == [] or a.runner_id in filter)
    end)
    |> case do
      nil -> nil
      action -> action.runner_id
    end
  end

  defp runner_allowed_by_key?(%{runner_filter: []}, _runner_id), do: true
  defp runner_allowed_by_key?(%{runner_filter: filter}, runner_id), do: runner_id in filter

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end

  # -- Plugs ----------------------------------------------------------

  defp authenticate(conn, _opts) do
    # Throttle BEFORE the DB lookup — otherwise a key-spraying attacker
    # forces `find_by_secret` (hash compare + Postgres query) on every
    # attempt regardless of the limit. 60/min/IP is well above any
    # honest client's mistyped-key rate.
    ip = ip_key(conn)

    case EmisarWeb.RateLimiter.check("mcp_auth:" <> ip, 60, 60_000) do
      {:error, :rate_limited, _ms} ->
        require Logger
        Logger.warning("mcp_auth.throttled", ip: ip)

        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limited"})
        |> halt()

      :ok ->
        with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
             %{} = key <- ApiKeys.find_by_secret(raw) do
          assign(conn, :api_key, key)
        else
          _ ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "unauthorized"})
            |> halt()
        end
    end
  end

  defp ip_key(conn), do: EmisarWeb.RateLimiter.ip_key(conn)

  defp require_scope(conn, scope) do
    key = conn.assigns.api_key

    if Enum.member?(key.scopes || [], scope) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "missing_scope", required: scope})
      |> halt()
    end
  end
end

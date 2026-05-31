defmodule EmisarWeb.McpController do
  @moduledoc """
  MCP / LLM tool surface. Authenticates via API key in the
  `Authorization: Bearer <key>` header.

  Endpoints:

    * `GET  /api/mcp/runners` — list the runners this key may dispatch
      to, with their metadata and advertised action ids. LLMs use this
      for discovery: "I want to operate on the primary cassandra node →
      look up the runner name, pass it as `runner` in the tool call."

    * `GET  /api/mcp/tools` — return MCP-shaped tool descriptors. One
      entry per distinct action_id. Each tool's input schema declares a
      `runners` array whose enum lists the runners advertising it; if
      exactly one runner advertises it, `runners` is optional and defaults
      to that runner.

    * `POST /api/mcp/tools/:action_id` — dispatch a run. Body is flat:

          {"runners": ["db-prod-01"], "reason": "...", ...action args}

      Defaults to fire-and-forget; add `?wait=15s` (max 60s) to long-poll
      for the result inline.

    * `GET  /api/mcp/runs/:id` — fetch run state with stdout / stderr.

  Every endpoint scopes by `api_key.account_id` AND respects the key's
  `runner_filter` allowlist: runners outside the filter are invisible
  in /runners, omitted from the runner enums in /tools, and rejected on
  dispatch.
  """

  use EmisarWeb, :controller

  alias Emisar.{Accounts, ApiKeys, Catalog, Runners, Runs}
  alias Emisar.Auth.Subject

  plug :authenticate
  plug :require_scope, "actions:read" when action in [:list_runners, :list_tools, :get_run]
  plug :require_scope, "actions:execute" when action in [:run_tool]

  # Hard cap on synchronous-call long-poll.
  @max_wait_ms 60_000
  @poll_interval_ms 200

  # GET /api/mcp/runners
  def list_runners(conn, _params) do
    api_key = conn.assigns.api_key
    actions_by_runner = group_actions_by_runner(conn)
    {:ok, all_runners, _} = Runners.list_runners_for_account(mcp_subject(conn))

    runners =
      all_runners
      |> Enum.reject(& &1.disabled_at)
      |> Enum.filter(&runner_visible_to_key?(&1, api_key))
      |> Enum.map(fn runner ->
        %{
          name: runner.name,
          hostname: runner.hostname,
          group: runner.group,
          labels: runner.labels || %{},
          status: runner.status,
          last_heartbeat_at: runner.last_heartbeat_at,
          runner_version: runner.runner_version,
          actions:
            actions_by_runner
            |> Map.get(runner.id, [])
            |> Enum.map(&action_summary/1)
        }
      end)

    json(conn, %{runners: runners})
  end

  # GET /api/mcp/tools
  def list_tools(conn, _params) do
    api_key = conn.assigns.api_key

    # Load runners once and reuse for both visibility filtering
    # (needs runner.group to evaluate runner_group_filter) and the
    # per-tool runner-id enum rendering downstream.
    {:ok, runners, _} = Runners.list_runners_for_account(mcp_subject(conn))
    runners_by_id = Map.new(runners, fn r -> {r.id, r} end)

    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))

    visible_actions =
      Enum.filter(actions, &action_visible_to_key?(&1, api_key, runners_by_id))

    tools =
      visible_actions
      |> Enum.group_by(& &1.action_id)
      |> Enum.map(fn {_action_id, group} -> mcp_tool_from_group(group, runners_by_id) end)
      |> Enum.sort_by(& &1.name)

    json(conn, %{tools: tools})
  end

  # POST /api/mcp/tools/:action_id
  #
  # Body shape (flat):
  #   {"runners": ["runner-1", "runner-2"], "reason": "...", ...action args}
  #
  # Returns `{runs: [{runner, run_id, status, ...}, ...]}` — always an
  # array, one element per dispatched runner, in input order. Per-run
  # status drives whether the LLM should call `wait_for_run` next on
  # each id (pending_approval / running) or treat it as final (success,
  # denied, etc.).
  def run_tool(conn, %{"action_id" => action_id} = params) do
    api_key = conn.assigns.api_key

    reason = params["reason"]
    runner_names = normalize_runner_input(params)

    # Anything the LLM passes beyond the known top-level keys is an
    # action arg. `wait` is a query param but Phoenix merges query +
    # body into params, so it may land here too.
    action_args = Map.drop(params, ["action_id", "reason", "runners", "wait"])

    case resolve_runners(conn, api_key, action_id, runner_names) do
      {:ok, resolved} ->
        results =
          Enum.map(resolved, fn {name, runner_id} ->
            attrs = %{
              action_id: action_id,
              runner_id: runner_id,
              args: action_args,
              reason: reason,
              source: "mcp",
              api_key_id: api_key.id
            }

            {name, Runs.dispatch_run(attrs, mcp_subject(conn))}
          end)

        respond_with_runs(conn, results, params["wait"])

      {:error, :runner_required, candidates} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "runner_required",
          message:
            "Multiple runners advertise this action; pass `runners` " <>
              "(array of one or more names) in the body.",
          candidates: candidates
        })

      {:error, :runner_not_found, name} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "runner_not_found", runner: name})

      {:error, :runner_not_allowed, name} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "runner_not_in_key_filter", runner: name})

      {:error, :no_runner_available} ->
        conn |> put_status(:not_found) |> json(%{error: "action_not_found"})

      {:error, :too_many_runners, max} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "too_many_runners",
          message: "Targeting more than #{max} runners in a single call isn't allowed."
        })
    end
  end

  # Hard cap on per-call fan-out — preventing a runaway LLM from
  # broadcasting one tool call to every host in the fleet at once.
  # Production accounts targeting a real fleet should iterate batches.
  @max_runners_per_call 16

  defp normalize_runner_input(params) do
    case params["runners"] do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  # GET /api/mcp/runs/:id
  #
  # Supports `?wait=Xs` (up to 300s) for long-polling: blocks until
  # the run reaches a terminal state (or the deadline expires). Used
  # by the bridge's synthetic `wait_for_run` MCP tool so the LLM can
  # park on a pending-approval run without tight client-side polling.
  def get_run(conn, %{"id" => id} = params) do
    subject = mcp_subject(conn)

    case Runs.fetch_run_by_id(id, subject) do
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:ok, run} ->
        case params["wait"] do
          nil ->
            json(conn, full_run_payload(run, subject))

          wait ->
            poll_run(conn, run, wait)
        end
    end
  end

  # The hard cap on /runs/:id?wait= is intentionally higher than the
  # one on tool dispatch — operators may need real minutes to look at
  # an approval, click through, and decide. 5 minutes is the longest a
  # single HTTP call can sit blocked here.
  @max_get_run_wait_ms 300_000

  defp poll_run(conn, run, wait) do
    subject = mcp_subject(conn)

    case parse_wait(wait, @max_get_run_wait_ms) do
      {:ok, 0} ->
        json(conn, full_run_payload(run, subject))

      {:ok, ms} ->
        deadline = System.monotonic_time(:millisecond) + ms

        case poll_to_terminal(subject, run.id, deadline) do
          {:terminal, final} ->
            json(conn, full_run_payload(final, subject))

          :timeout ->
            current =
              case Runs.fetch_run_by_id(run.id, subject) do
                {:ok, r} -> r
                {:error, _} -> run
              end

            conn
            |> put_status(:accepted)
            |> json(
              Map.merge(full_run_payload(current, subject), %{
                waiting: "timeout",
                tip:
                  "Run is still not terminal. Call `wait_for_run` again with the same id to continue waiting."
              })
            )
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_wait", expected: "duration string e.g. '60s', max 300s"})
    end
  end

  # -- Runner resolution -----------------------------------------------

  # When the LLM omits `runners`, dispatch only auto-picks if exactly
  # one allowed runner advertises the action. Two or more → ambiguous,
  # the LLM is asked to choose one or more by name. When the LLM
  # supplies a non-empty `runners` array, every name is resolved
  # independently; the first error wins (we don't partially dispatch).
  defp resolve_runners(conn, api_key, action_id, []) do
    case allowed_runners_for_action(conn, api_key, action_id) do
      [] -> {:error, :no_runner_available}
      [one] -> {:ok, [{one.name, one.id}]}
      candidates -> {:error, :runner_required, Enum.map(candidates, & &1.name)}
    end
  end

  defp resolve_runners(_conn, _api_key, _action_id, names) when length(names) > @max_runners_per_call,
    do: {:error, :too_many_runners, @max_runners_per_call}

  defp resolve_runners(conn, api_key, action_id, names) do
    allowed = allowed_runners_for_action(conn, api_key, action_id)
    {:ok, all, _} = Runners.list_runners_for_account(mcp_subject(conn))

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case resolve_one(allowed, all, name) do
        {:ok, runner_id} -> {:cont, {:ok, [{name, runner_id} | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp resolve_one(allowed, all, name) do
    case Enum.find(allowed, &(&1.name == name)) do
      %{id: id} ->
        {:ok, id}

      nil ->
        # Disambiguate "spelled it wrong" vs "your key can't reach it"
        # so the LLM can decide whether to try a different name or
        # surface the auth issue to the operator.
        case Enum.find(all, &(&1.name == name)) do
          nil -> {:error, :runner_not_found, name}
          _ -> {:error, :runner_not_allowed, name}
        end
    end
  end

  defp allowed_runners_for_action(conn, api_key, action_id) do
    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))

    runner_ids_advertising =
      actions
      |> Enum.filter(&(&1.action_id == action_id))
      |> Enum.map(& &1.runner_id)
      |> MapSet.new()

    {:ok, runners, _} = Runners.list_runners_for_account(mcp_subject(conn))

    runners
    |> Enum.reject(& &1.disabled_at)
    |> Enum.filter(&(&1.id in runner_ids_advertising))
    |> Enum.filter(&runner_visible_to_key?(&1, api_key))
  end

  # -- Tool descriptor + JSON Schema (draft 2020-12) ------------------

  defp mcp_tool_from_group([first | _] = group, runners_by_id) do
    runners =
      group
      |> Enum.map(&Map.get(runners_by_id, &1.runner_id))
      |> Enum.reject(&is_nil/1)

    runner_names = runners |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

    %{
      name: first.action_id,
      description: tool_description(first, runner_names),
      inputSchema: build_input_schema(first, runner_names)
    }
  end

  # Many LLMs treat the description as the canonical safety brief. Pack
  # everything the model needs into it: action intent, side effects,
  # runner availability, risk label.
  defp tool_description(action, runner_names) do
    base = action.description || action.title || action.action_id

    side_effects =
      case action.side_effects || [] do
        [] -> ""
        list -> "\n\nSide effects:\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    hosts =
      case runner_names do
        [] -> ""
        [one] -> "\n\nRuns on: #{one}"
        many -> "\n\nAvailable runners: #{Enum.join(many, ", ")}"
      end

    base <> side_effects <> hosts <> "\n\nRisk: #{action.risk}"
  end

  defp build_input_schema(action, runner_names) do
    args = action.args_schema["args"] || []

    arg_properties =
      args
      |> Enum.map(fn arg -> {arg["name"], arg_to_json_schema(arg)} end)
      |> Map.new()

    arg_required =
      args |> Enum.filter(& &1["required"]) |> Enum.map(& &1["name"])

    reason_prop = %{
      type: "string",
      description:
        "Why you are running this action — a short freeform sentence. Logged in the immutable audit trail. Required."
    }

    {runners_prop, runners_required} = runners_property(runner_names)

    properties =
      arg_properties
      |> Map.put("reason", reason_prop)
      |> maybe_put("runners", runners_prop)

    required =
      ["reason" | arg_required]
      |> then(fn r -> if runners_required, do: ["runners" | r], else: r end)

    %{
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      type: "object",
      properties: properties,
      required: required,
      additionalProperties: false
    }
  end

  defp runners_property([]), do: {nil, false}

  defp runners_property([only]) do
    {%{
       type: "array",
       items: %{type: "string", enum: [only]},
       minItems: 1,
       maxItems: 1,
       default: [only],
       description:
         "Runners to execute on. Only `#{only}` advertises this action — safe to omit."
     }, false}
  end

  defp runners_property(many) do
    {%{
       type: "array",
       items: %{type: "string", enum: many},
       minItems: 1,
       maxItems: min(length(many), 16),
       description:
         "REQUIRED. One or more runner names from the `enum`. " <>
           "The call fans out and each runner runs independently. " <>
           "Pass `[\"runner-1\"]` to target a single host, or " <>
           "`[\"runner-1\",\"runner-2\"]` to run on multiple. " <>
           "Each returned run carries its own status — some may " <>
           "succeed immediately while others need approval."
     }, true}
  end

  # Translate one emisar arg descriptor → one JSON Schema 2020-12
  # property. Emisar's own types (duration, string_array, integer_array)
  # don't exist in JSON Schema, so we widen them to the underlying
  # primitive and carry the constraint via pattern / items. The runner
  # re-validates with the original spec, so a model that yields a
  # `duration` literally as "5m" gets the same gate it always would.
  defp arg_to_json_schema(arg) do
    arg["type"]
    |> type_to_json_schema()
    |> maybe_put_string(:description, arg["description"])
    |> maybe_put_default(arg["default"])
    |> apply_validation(arg["validation"] || %{})
  end

  defp type_to_json_schema("string"), do: %{type: "string"}
  defp type_to_json_schema("integer"), do: %{type: "integer"}
  defp type_to_json_schema("number"), do: %{type: "number"}
  defp type_to_json_schema("boolean"), do: %{type: "boolean"}

  defp type_to_json_schema("duration"),
    do: %{type: "string", pattern: "^[0-9]+(ns|us|ms|s|m|h)$"}

  defp type_to_json_schema("string_array"),
    do: %{type: "array", items: %{type: "string"}}

  defp type_to_json_schema("integer_array"),
    do: %{type: "array", items: %{type: "integer"}}

  # Unknown / missing — widen to string so the schema is still a valid
  # 2020-12 document. The runner's stricter validation catches misuse.
  defp type_to_json_schema(_), do: %{type: "string"}

  defp apply_validation(map, %{} = v) do
    map
    |> maybe_put_enum(v["enum"] || v["allowed"])
    |> maybe_put_string(:pattern, v["pattern"])
    |> maybe_put_number(:minimum, v["min"])
    |> maybe_put_number(:maximum, v["max"])
    |> maybe_put_number(:maxItems, v["max_items"])
    |> maybe_put_number(:minItems, v["min_items"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, val) when is_binary(val), do: Map.put(map, key, val)

  defp maybe_put_number(map, _key, nil), do: map
  defp maybe_put_number(map, key, val) when is_number(val), do: Map.put(map, key, val)
  defp maybe_put_number(map, _key, _), do: map

  defp maybe_put_default(map, nil), do: map
  defp maybe_put_default(map, default), do: Map.put(map, :default, default)

  defp maybe_put_enum(map, nil), do: map
  defp maybe_put_enum(map, []), do: map
  defp maybe_put_enum(map, list) when is_list(list), do: Map.put(map, :enum, list)

  # -- Visibility / filtering helpers ---------------------------------

  # A runner is visible to the key when EITHER filter is empty (no
  # restriction) OR the runner's id is in `runner_filter` OR the
  # runner's group is in `runner_group_filter`. The two filters are
  # additive — operators commonly set just one (group for "DBA team",
  # id list for a tightly-scoped break-glass key).
  defp runner_visible_to_key?(runner, api_key) do
    no_filter?(api_key) or
      runner.id in api_key.runner_filter or
      runner.group in (api_key.runner_group_filter || [])
  end

  # Action visibility needs the runner's group, which isn't on the
  # action row — caller passes a runner_id → runner map so we don't
  # do an N+1 DB hit per action.
  defp action_visible_to_key?(action, api_key, runners_by_id) do
    cond do
      no_filter?(api_key) ->
        true

      action.runner_id in api_key.runner_filter ->
        true

      true ->
        case Map.get(runners_by_id, action.runner_id) do
          %{group: group} -> group in (api_key.runner_group_filter || [])
          _ -> false
        end
    end
  end

  defp no_filter?(api_key) do
    api_key.runner_filter == [] and (api_key.runner_group_filter || []) == []
  end

  defp group_actions_by_runner(conn) do
    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))
    Enum.group_by(actions, & &1.runner_id)
  end

  defp action_summary(action) do
    %{
      action_id: action.action_id,
      title: action.title,
      kind: action.kind,
      risk: action.risk
    }
  end

  # -- Per-runner dispatch + multi-runner response ---------------------

  # Status strings the runner can reach from which no further state
  # change is expected. `pending_approval` is NOT included — that's
  # waiting on a human and uses `wait_for_run` to block.
  @terminal_statuses ~w(success failed error validation_failed unknown_action cancelled timed_out denied)

  # Render the per-runner runs array. When `wait` is supplied (and at
  # least one run is non-terminal), block until all running runs reach
  # terminal OR the deadline expires, then return whatever's current.
  defp respond_with_runs(conn, results, wait) do
    case parse_wait(wait || "0", @max_wait_ms) do
      {:ok, ms} ->
        subject = mcp_subject(conn)
        maybe_poll_to_terminal(subject, results, ms)
        runs = Enum.map(results, &runner_result_to_json(&1, subject))
        conn |> put_status(:accepted) |> json(%{runs: runs})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_wait", expected: "duration string e.g. '15s', max 60s"})
    end
  end

  defp maybe_poll_to_terminal(_subject, _results, 0), do: :ok

  defp maybe_poll_to_terminal(subject, results, ms) do
    # Pending-approval requires human input; only block on actively-
    # running runs here.
    polling_ids =
      for {_name, {:ok, :running, %{id: id}}} <- results, do: id

    if polling_ids == [] do
      :ok
    else
      deadline = System.monotonic_time(:millisecond) + ms
      poll_all_to_terminal(subject, polling_ids, deadline)
    end
  end

  defp poll_all_to_terminal(subject, ids, deadline) do
    remaining = Enum.reject(ids, &run_terminal?(&1, subject))

    cond do
      remaining == [] -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :ok
      true ->
        Process.sleep(@poll_interval_ms)
        poll_all_to_terminal(subject, remaining, deadline)
    end
  end

  defp run_terminal?(run_id, subject) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:ok, %{status: s}} when s in @terminal_statuses -> true
      _ -> false
    end
  end

  # Per-runner JSON for the {runs: [...]} response.
  defp runner_result_to_json({name, {:ok, :running, run}}, subject) do
    # Re-fetch in case the long-poll updated state.
    fresh =
      case Runs.fetch_run_by_id(run.id, subject) do
        {:ok, r} -> r
        {:error, _} -> run
      end

    fresh
    |> full_run_payload(subject)
    |> Map.put(:runner, name)
  end

  defp runner_result_to_json({name, {:ok, :pending_approval, run}}, _subject) do
    %{
      runner: name,
      run_id: run.id,
      status: "pending_approval",
      waiting_on: "approval",
      tip:
        "Operator approval required. Use the `wait_for_run` tool with run_id=#{run.id} to block until the decision."
    }
  end

  defp runner_result_to_json({name, {:error, :denied_by_policy, reason}}, _subject),
    do: %{runner: name, status: "denied_by_policy", reason: reason}

  defp runner_result_to_json({name, {:error, %Ecto.Changeset{} = cs}}, _subject),
    do: %{runner: name, status: "error", error: "invalid", details: errors(cs)}

  # Dispatch error codes that map to a flat `{status: "error", error: ...}`
  # payload. Adding a new one is one line; only `reason_required`
  # carries an extra human-readable message because the atom alone
  # doesn't tell the LLM what to do next.
  @dispatch_error_codes ~w(runner_not_found runner_required action_not_found action_required reason_required)a

  defp runner_result_to_json({name, {:error, code}}, _subject) when code in @dispatch_error_codes,
    do: error_payload(name, code)

  defp runner_result_to_json({name, other}, _subject),
    do: %{runner: name, status: "error", error: "unknown", details: inspect(other)}

  defp error_payload(name, :reason_required),
    do: %{
      runner: name,
      status: "error",
      error: "reason_required",
      message: "Every action call must include a non-empty `reason` field describing why."
    }

  defp error_payload(name, code),
    do: %{runner: name, status: "error", error: Atom.to_string(code)}

  defp poll_to_terminal(subject, run_id, deadline) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:error, :not_found} ->
        :timeout

      {:ok, %{status: status} = run} when status in @terminal_statuses ->
        {:terminal, run}

      {:ok, _} ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          :timeout
        else
          Process.sleep(min(@poll_interval_ms, max(deadline - now, 1)))
          poll_to_terminal(subject, run_id, deadline)
        end
    end
  end

  # Accepts "15s", "1m", "500ms"; clamps to `max_ms` (caller picks the
  # cap so /tools/:id can be tighter than /runs/:id).
  defp parse_wait(s, max_ms) when is_binary(s) do
    case Regex.run(~r/^(\d+)(ms|s|m)?$/, s) do
      [_, num, unit] ->
        ms = String.to_integer(num) * unit_to_ms(unit)
        {:ok, min(ms, max_ms)}

      [_, num] ->
        ms = String.to_integer(num) * 1000
        {:ok, min(ms, max_ms)}

      _ ->
        :error
    end
  end

  defp parse_wait(_, _), do: :error

  defp unit_to_ms(""), do: 1000
  defp unit_to_ms("ms"), do: 1
  defp unit_to_ms("s"), do: 1000
  defp unit_to_ms("m"), do: 60_000

  # -- Run payload (incl. output) -------------------------------------

  @stdout_cap 65_536
  @stderr_cap 65_536

  defp full_run_payload(run, subject) do
    {:ok, events, _meta} = Runs.list_events_for_run(run.id, subject, page: [limit: 5_000])
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
    # forces hash compare + Postgres query on every attempt regardless
    # of the limit. 60/min/IP is well above any honest client's rate.
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
             %{} = key <- ApiKeys.peek_api_key_by_secret(raw),
             {:ok, account} <- Accounts.fetch_account_by_id(key.account_id) do
          conn
          |> assign(:api_key, key)
          |> assign(:current_subject, Subject.for_api_key(key, account))
        else
          _ ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "unauthorized"})
            |> halt()
        end
    end
  end

  defp mcp_subject(conn), do: conn.assigns.current_subject

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

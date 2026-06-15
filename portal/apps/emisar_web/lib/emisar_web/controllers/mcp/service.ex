defmodule EmisarWeb.Mcp.Service do
  @moduledoc """
  Shared business layer behind every MCP surface — the REST controller
  (`EmisarWeb.McpController`) and the JSON-RPC controller
  (`EmisarWeb.Mcp.RpcController`).

  Returns plain data structures (lists, maps). Wrapping into HTTP /
  JSON-RPC envelopes is the caller's job.

  Every function takes a `conn` and reads `conn.assigns.api_key`
  + `conn.assigns.current_subject` (both set by the auth plug shared
  with McpController). No DB access bypasses the existing context
  modules — `Catalog`, `Runners`, `Runs`.
  """

  alias Emisar.{Catalog, Runbooks, Runners, Runs}
  alias EmisarWeb.Mcp.{Idempotency, ToolSchema}
  require Logger

  # Same caps the REST handlers use; keep them in lockstep so
  # behavior matches whether the LLM hits /api/mcp/tools/:id or the
  # JSON-RPC equivalent.
  @max_runners_per_call 16
  @max_wait_ms 60_000
  # Cap a long-poll at 90s so a `wait_for_run` can't pin a request process for
  # five minutes; clients re-poll if the run is still running.
  @max_get_run_wait_ms 90_000
  # The wait is event-driven — it blocks on the run's PubSub topic and wakes on
  # each `{:run_updated, _}` broadcast. This timer is only the safety net: a
  # missed broadcast, or a state change that doesn't broadcast at all, is still
  # caught within ~2s. ~10× fewer DB queries than the old 200ms busy-poll while
  # staying robust.
  @recheck_interval_ms 2_000

  @terminal_statuses [
    :success,
    :failed,
    :error,
    :validation_failed,
    :unknown_action,
    :cancelled,
    :timed_out,
    :denied
  ]

  @stdout_cap 65_536
  @stderr_cap 65_536

  # -- Tool list -------------------------------------------------------

  @doc """
  Build the tool descriptors this API key can dispatch. Same shape the
  REST `GET /api/mcp/tools` returns under the `tools` key. One entry
  per distinct `action_id`, sorted alphabetically.
  """
  @spec list_tools(Plug.Conn.t()) :: [map()]
  def list_tools(conn) do
    api_key = conn.assigns.api_key
    subject = conn.assigns.current_subject

    {:ok, runners} = Runners.list_all_runners_for_account(subject)
    runners_by_id = Map.new(runners, fn r -> {r.id, r} end)
    scopes = membership_scopes(api_key)

    {:ok, actions} = Catalog.list_all_actions_for_account(subject)

    actions
    |> Enum.filter(
      &(action_visible_to_key?(&1, api_key, runners_by_id) and
          action_in_membership_scope?(&1, runners_by_id, scopes))
    )
    |> Enum.group_by(& &1.action_id)
    |> Enum.map(fn {_action_id, group} -> mcp_tool_from_group(group, runners_by_id) end)
    |> Enum.sort_by(& &1.name)
  end

  # -- Runner list -----------------------------------------------------

  @doc """
  Runner inventory the API key can reach, with per-runner action
  summaries. Same shape REST `GET /api/mcp/runners` returns under
  the `runners` key.
  """
  @spec list_runners(Plug.Conn.t()) :: [map()]
  def list_runners(conn) do
    api_key = conn.assigns.api_key
    subject = conn.assigns.current_subject

    {:ok, actions} = Catalog.list_all_actions_for_account(subject)
    actions_by_runner = Enum.group_by(actions, & &1.runner_id)

    {:ok, all_runners} = Runners.list_all_runners_for_account(subject)
    scopes = membership_scopes(api_key)

    all_runners
    |> Enum.reject(& &1.disabled_at)
    |> Enum.filter(
      &(runner_visible_to_key?(&1, api_key) and Runners.runner_in_scope?(&1, scopes))
    )
    |> Enum.map(fn runner ->
      %{
        name: runner.name,
        hostname: runner.hostname,
        group: runner.group,
        labels: runner.labels || %{},
        status: runner_wire_status(runner),
        last_heartbeat_at: runner.last_heartbeat_at,
        runner_version: runner.runner_version,
        actions:
          actions_by_runner
          |> Map.get(runner.id, [])
          |> Enum.map(&action_summary/1)
      }
    end)
  end

  # -- Runbooks (read-only) -------------------------------------------

  @doc """
  Published runbooks for the account — latest version per slug, as
  summary maps. The MCP exposes these read-only so an LLM can follow a
  runbook by dispatching its steps itself; the cloud never runs them.
  """
  @spec list_runbooks(Plug.Conn.t()) :: {:ok, [map()]} | {:error, :unauthorized}
  def list_runbooks(conn) do
    subject = conn.assigns.current_subject

    case Runbooks.list_runbooks(subject, page: [limit: 1000]) do
      {:ok, runbooks, _meta} ->
        summaries =
          runbooks
          |> published_latest_per_slug()
          |> Enum.map(&runbook_summary/1)
          |> Enum.sort_by(& &1.slug)

        {:ok, summaries}

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  One published runbook's full definition, by slug (or id), with each
  step's runner selector resolved to current runner names so the LLM can
  dispatch directly. `{:error, :not_found}` if no published runbook matches.
  """
  @spec get_runbook(Plug.Conn.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :unauthorized}
  def get_runbook(conn, slug_or_id) do
    subject = conn.assigns.current_subject

    case Runbooks.list_runbooks(subject, page: [limit: 1000]) do
      {:ok, runbooks, _meta} ->
        case find_runbook(published_latest_per_slug(runbooks), slug_or_id) do
          nil ->
            {:error, :not_found}

          runbook ->
            {:ok, runners} = Runners.list_all_runners_for_account(subject)
            {:ok, runbook_detail(runbook, runners)}
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  defp published_latest_per_slug(runbooks) do
    runbooks
    |> Enum.filter(&(&1.status == :published))
    |> Enum.group_by(& &1.slug)
    |> Enum.map(fn {_slug, versions} -> Enum.max_by(versions, & &1.version) end)
  end

  defp find_runbook(runbooks, slug_or_id) do
    Enum.find(runbooks, &(&1.slug == slug_or_id)) ||
      Enum.find(runbooks, &(&1.id == slug_or_id))
  end

  defp runbook_summary(runbook) do
    steps = runbook_steps(runbook)

    %{
      slug: runbook.slug,
      title: runbook.title,
      version: runbook.version,
      description: nil_if_blank(runbook.description),
      steps: length(steps),
      actions:
        steps |> Enum.map(&Map.get(&1, "action_id")) |> Enum.reject(&blank?/1) |> Enum.uniq()
    }
  end

  defp runbook_detail(runbook, runners) do
    %{
      slug: runbook.slug,
      title: runbook.title,
      version: runbook.version,
      description: nil_if_blank(runbook.description),
      steps: runbook |> runbook_steps() |> Enum.map(&runbook_step(&1, runners))
    }
  end

  defp runbook_step(step, runners) do
    {by, values} = Runbooks.StepSelector.parse(Map.get(step, "runner_selector"))

    %{
      id: Map.get(step, "id"),
      action_id: Map.get(step, "action_id"),
      args: Map.get(step, "args") || %{},
      target: %{by: by, values: values, runners: resolve_targets(by, values, runners)}
    }
  end

  defp resolve_targets("runner_id", ids, runners),
    do: runners |> Enum.filter(&(&1.id in ids)) |> Enum.map(& &1.name)

  defp resolve_targets(_group, groups, runners),
    do: runners |> Enum.filter(&(&1.group in groups)) |> Enum.map(& &1.name) |> Enum.uniq()

  defp runbook_steps(runbook), do: get_in(runbook.definition || %{}, ["steps"]) || []

  defp blank?(s), do: s in [nil, ""]
  defp nil_if_blank(s), do: if(blank?(s), do: nil, else: s)

  # -- Recent runs (read-only) ----------------------------------------

  @doc """
  The `recent_runs` synthetic tool: the calling agent's (or the whole
  account's) most recent runs, newest first, as compact summaries.
  """
  @spec recent_runs(Plug.Conn.t(), pos_integer(), :own | :account) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def recent_runs(conn, limit, scope) do
    subject = conn.assigns.current_subject

    case Runs.list_recent_runs(subject, scope: scope, limit: limit, preload: [:runner]) do
      {:ok, runs, _meta} -> {:ok, Enum.map(runs, &run_summary/1)}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp run_summary(run) do
    %{
      run_id: run.id,
      action_id: run.action_id,
      runner: run.runner && run.runner.name,
      status: run.status,
      exit_code: run.exit_code,
      reason: run.reason,
      finished_at: run.finished_at
    }
  end

  # -- Dispatch --------------------------------------------------------

  @type dispatch_opts :: %{
          optional(:runner_names) => [String.t()],
          optional(:reason) => String.t() | nil,
          optional(:wait_ms) => non_neg_integer(),
          optional(:idempotency_key) => String.t() | nil
        }

  @type dispatch_error ::
          {:error, :runner_required, [String.t()]}
          | {:error, :runner_not_found, String.t()}
          | {:error, :runner_not_allowed, String.t(), String.t()}
          | {:error, :no_runner_available, :unknown_action | :scope_blocked}
          | {:error, :too_many_runners, pos_integer()}

  @doc """
  Dispatch one action against the resolved runners.

  Returns `{:ok, [run_result_map]}` on success — one entry per runner
  in input order, post-long-poll. Errors mirror the REST 4xx body
  shapes so error rendering is identical across surfaces.
  """
  @spec dispatch_tool(Plug.Conn.t(), String.t(), map(), dispatch_opts) ::
          {:ok, [map()]} | dispatch_error()
  def dispatch_tool(conn, action_id, args, opts \\ %{}) do
    api_key = conn.assigns.api_key
    subject = conn.assigns.current_subject

    runner_names = Map.get(opts, :runner_names, [])
    reason = Map.get(opts, :reason)
    idempotency_key = Map.get(opts, :idempotency_key)
    wait_ms = Map.get(opts, :wait_ms, 0)
    mcp_session_id = Map.get(opts, :mcp_session_id)

    with {:ok, resolved} <- resolve_runners(subject, api_key, action_id, runner_names) do
      runners_by_id = fetch_runners_by_id(subject, Enum.map(resolved, fn {_, id} -> id end))

      results =
        Enum.map(resolved, fn {name, runner_id} ->
          per_runner_key = Idempotency.per_runner(idempotency_key, runner_id)

          attrs = %{
            action_id: action_id,
            runner_id: runner_id,
            args: args,
            reason: reason,
            source: "mcp",
            api_key_id: api_key.id,
            client_info: api_key.last_client_info || %{},
            mcp_session_id: mcp_session_id,
            idempotency_key: per_runner_key,
            requested_by_membership_id: api_key.created_by_membership_id
          }

          result = Runs.dispatch_run(attrs, subject)
          {name, result, Map.get(runners_by_id, runner_id)}
        end)

      maybe_poll_to_terminal(subject, results, wait_ms)
      {:ok, Enum.map(results, &runner_result_to_json(&1, subject))}
    end
  end

  # -- Run fetch + long-poll ------------------------------------------

  @doc """
  Single run state, with optional long-poll until terminal. `wait_ms`
  is clamped to 300s. Returns `{:ok, payload, status}` where status
  is `:terminal` or `:waiting` so the caller can choose a 200 vs 202.
  """
  @spec fetch_run(Plug.Conn.t(), String.t(), non_neg_integer()) ::
          {:ok, map(), :terminal | :waiting} | {:error, :not_found | :invalid_wait}
  def fetch_run(conn, id, wait_ms) when is_integer(wait_ms) and wait_ms >= 0 do
    subject = conn.assigns.current_subject

    case Runs.fetch_run_by_id(id, subject) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, run} ->
        if wait_ms == 0 do
          {:ok, full_run_payload(run, subject), run_status_kind(run)}
        else
          deadline = System.monotonic_time(:millisecond) + min(wait_ms, @max_get_run_wait_ms)

          case poll_to_terminal(subject, run.id, deadline) do
            {:terminal, final} ->
              {:ok, full_run_payload(final, subject), :terminal}

            :timeout ->
              current =
                case Runs.fetch_run_by_id(run.id, subject) do
                  {:ok, r} -> r
                  {:error, _} -> run
                end

              {:ok, full_run_payload(current, subject), :waiting}
          end
        end
    end
  end

  # -- Helpers exposed for both controllers ---------------------------

  @doc ~s(Accepts "15s", "1m", "500ms"; clamped to `max_ms`.)
  @spec parse_wait(String.t() | nil, pos_integer()) :: {:ok, non_neg_integer()} | :error
  def parse_wait(nil, _max_ms), do: {:ok, 0}
  def parse_wait("", _max_ms), do: {:ok, 0}

  def parse_wait(s, max_ms) when is_binary(s) do
    # `\d{1,8}` caps the magnitude (~27h, far past max_ms) so a `wait=<huge>`
    # can't allocate a giant bignum before the clamp; longer input is rejected.
    case Regex.run(~r/^(\d{1,8})(ms|s|m)?$/, s) do
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

  def parse_wait(_, _), do: :error

  def max_wait_ms, do: @max_wait_ms
  def max_get_run_wait_ms, do: @max_get_run_wait_ms
  def max_runners_per_call, do: @max_runners_per_call
  def terminal_statuses, do: @terminal_statuses

  # -- Runner resolution ----------------------------------------------

  defp resolve_runners(subject, api_key, action_id, []) do
    case allowed_runners_for_action(subject, api_key, action_id) do
      [] ->
        if action_exists_in_account?(subject, action_id),
          do: {:error, :no_runner_available, :scope_blocked},
          else: {:error, :no_runner_available, :unknown_action}

      [one] ->
        {:ok, [{one.name, one.id}]}

      candidates ->
        {:error, :runner_required, Enum.map(candidates, & &1.name)}
    end
  end

  defp resolve_runners(_subject, _api_key, _action_id, names)
       when length(names) > @max_runners_per_call,
       do: {:error, :too_many_runners, @max_runners_per_call}

  defp resolve_runners(subject, api_key, action_id, names) do
    allowed = allowed_runners_for_action(subject, api_key, action_id)
    {:ok, all} = Runners.list_all_runners_for_account(subject)
    scopes = membership_scopes(api_key)

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case resolve_one(allowed, all, api_key, scopes, name) do
        {:ok, runner_id} -> {:cont, {:ok, [{name, runner_id} | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # Names are unique among live runners (enforced at register time + by a
  # partial unique index), so at most one allowed runner matches a name.
  defp resolve_one(allowed, all, api_key, scopes, name) do
    case Enum.find(allowed, &(&1.name == name)) do
      %{id: id} ->
        {:ok, id}

      nil ->
        case Enum.find(all, &(&1.name == name)) do
          nil ->
            {:error, :runner_not_found, name}

          %_{} = runner ->
            {:error, :runner_not_allowed, name, deny_reason(runner, api_key, scopes)}
        end
    end
  end

  defp deny_reason(runner, api_key, scopes) do
    cond do
      runner.disabled_at ->
        "runner is disabled"

      not runner_visible_to_key?(runner, api_key) ->
        "the API key's runner_filter / runner_group_filter doesn't include it"

      not Runners.runner_in_scope?(runner, scopes) ->
        "the user who minted this key has no runner-scope grant for it"

      true ->
        "no advertised action with this name on this runner"
    end
  end

  defp action_exists_in_account?(subject, action_id) do
    {:ok, actions} = Catalog.list_all_actions_for_account(subject)
    Enum.any?(actions, &(&1.action_id == action_id))
  end

  defp allowed_runners_for_action(subject, api_key, action_id) do
    {:ok, actions} = Catalog.list_all_actions_for_account(subject)

    runner_ids_advertising =
      actions
      |> Enum.filter(&(&1.action_id == action_id))
      |> Enum.map(& &1.runner_id)
      |> MapSet.new()

    {:ok, runners} = Runners.list_all_runners_for_account(subject)
    scopes = membership_scopes(api_key)

    runners
    |> Enum.reject(& &1.disabled_at)
    |> Enum.filter(
      &(&1.id in runner_ids_advertising and runner_visible_to_key?(&1, api_key) and
          Runners.runner_in_scope?(&1, scopes))
    )
  end

  defp fetch_runners_by_id(subject, ids) do
    {:ok, all} = Runners.list_all_runners_for_account(subject)
    Map.new(all, fn r -> {r.id, r} end) |> Map.take(ids)
  end

  # -- Tool descriptor builder ----------------------------------------

  defp mcp_tool_from_group([first | _] = group, runners_by_id) do
    runners =
      group
      |> Enum.map(&Map.get(runners_by_id, &1.runner_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{runner_status_rank(&1), &1.name})

    runner_names = runners |> Enum.map(& &1.name) |> Enum.uniq()

    %{
      name: first.action_id,
      description: tool_description(first, runners),
      inputSchema: ToolSchema.build(first, runner_names)
    }
  end

  defp runner_status_rank(runner), do: if(runner.online?, do: 0, else: 1)

  defp tool_description(action, runners) do
    base = action.description || action.title || action.action_id

    side_effects =
      case action.side_effects || [] do
        [] -> ""
        list -> "\n\nSide effects:\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    hosts =
      case runners do
        [] ->
          ""

        [only] ->
          "\n\nRuns on: #{only.name} (#{runner_status_label(only)})"

        many ->
          lines =
            Enum.map_join(
              many,
              "\n",
              &("- " <> &1.name <> " (" <> runner_status_label(&1) <> ")")
            )

          "\n\nAvailable runners (pick one or more by name):\n" <> lines
      end

    base <> side_effects <> hosts <> "\n\nRisk: #{action.risk}"
  end

  defp runner_status_label(runner) do
    case Runners.connection_state(runner) do
      :online -> "connected"
      :pending -> "never connected"
      :disabled -> last_seen_label("disabled", runner)
      :offline -> last_seen_label("disconnected", runner)
    end
  end

  defp last_seen_label(word, %{last_disconnected_at: %DateTime{} = ts}),
    do: "#{word} (last seen " <> human_ago(ts) <> " ago)"

  defp last_seen_label(word, _runner), do: word

  # Wire-facing connection word for the /runners JSON. Keeps the
  # pre-presence vocabulary so existing MCP clients don't break.
  defp runner_wire_status(runner) do
    case Runners.connection_state(runner) do
      :online -> "connected"
      :offline -> "disconnected"
      :disabled -> "disabled"
      :pending -> "pending"
    end
  end

  defp human_ago(%DateTime{} = ts) do
    seconds = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      seconds < 60 -> "#{max(seconds, 0)}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp human_ago(_), do: "unknown"

  defp action_summary(action),
    do: %{action_id: action.action_id, title: action.title, kind: action.kind, risk: action.risk}

  # -- Visibility / membership ----------------------------------------

  defp runner_visible_to_key?(runner, api_key) do
    no_filter?(api_key) or
      runner.id in api_key.runner_filter or
      runner.group in (api_key.runner_group_filter || [])
  end

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

  defp no_filter?(api_key),
    do: api_key.runner_filter == [] and (api_key.runner_group_filter || []) == []

  defp membership_scopes(%{created_by_membership_id: nil}), do: []

  defp membership_scopes(%{created_by_membership_id: id}),
    do: Runners.runner_scopes_for_membership(id)

  defp membership_scopes(_), do: []

  defp action_in_membership_scope?(_action, _runners_by_id, []), do: true

  defp action_in_membership_scope?(action, runners_by_id, scopes) do
    case Map.get(runners_by_id, action.runner_id) do
      %{} = runner -> Runners.runner_in_scope?(runner, scopes)
      _ -> false
    end
  end

  # -- Per-runner long-poll + result rendering ------------------------

  defp maybe_poll_to_terminal(_subject, _results, 0), do: :ok

  defp maybe_poll_to_terminal(subject, results, ms) do
    polling_ids =
      for {_name, {:ok, :running, %{id: id}}, _runner} <- results, do: id

    if polling_ids == [] do
      :ok
    else
      deadline = System.monotonic_time(:millisecond) + ms
      poll_all_to_terminal(subject, polling_ids, deadline)
    end
  end

  # Block until every run in `ids` is terminal or the deadline passes. The
  # runner socket broadcasts `{:run_updated, _}` on each run's topic at every
  # state transition (Runs broadcasts on the run topic), so we subscribe and wake
  # on those instead of busy-polling; the recheck timer is the safety net.
  defp poll_all_to_terminal(subject, ids, deadline) do
    Enum.each(ids, &Runs.subscribe_run(subject.account.id, &1))
    schedule_recheck(deadline)

    try do
      await_all_terminal(subject, ids, deadline)
    after
      Enum.each(ids, &Runs.unsubscribe_run(subject.account.id, &1))
    end
  end

  defp await_all_terminal(subject, ids, deadline) do
    remaining = Enum.reject(ids, &run_terminal?(&1, subject))

    if remaining == [] do
      :ok
    else
      case wait_for_signal(deadline) do
        :recheck ->
          schedule_recheck(deadline)
          await_all_terminal(subject, remaining, deadline)

        {:run_updated, _run} ->
          await_all_terminal(subject, remaining, deadline)

        :timeout ->
          :ok
      end
    end
  end

  defp run_terminal?(run_id, subject) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:ok, %{status: s}} when s in @terminal_statuses -> true
      _ -> false
    end
  end

  defp run_status_kind(%{status: s}) when s in @terminal_statuses, do: :terminal
  defp run_status_kind(_), do: :waiting

  # Single-run variant of the above, returning the terminal run for the caller
  # to render. Same event-driven wait; one subscription instead of N.
  defp poll_to_terminal(subject, run_id, deadline) do
    Runs.subscribe_run(subject.account.id, run_id)
    schedule_recheck(deadline)

    try do
      await_terminal(subject, run_id, deadline)
    after
      Runs.unsubscribe_run(subject.account.id, run_id)
    end
  end

  defp await_terminal(subject, run_id, deadline) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:error, :not_found} ->
        :timeout

      {:ok, %{status: status} = run} when status in @terminal_statuses ->
        {:terminal, run}

      {:ok, _} ->
        case wait_for_signal(deadline) do
          :recheck ->
            schedule_recheck(deadline)
            await_terminal(subject, run_id, deadline)

          {:run_updated, _run} ->
            await_terminal(subject, run_id, deadline)

          :timeout ->
            :timeout
        end
    end
  end

  # Block until a relevant PubSub message arrives, the recheck timer fires, or
  # the deadline's remaining budget elapses — whichever comes first. Returns the
  # signal so the caller decides whether to re-check the run(s) or give up.
  # `{:run_event, _}` progress chunks are drained in place (they don't change
  # status, so re-querying on each would re-amplify DB load on a chatty run)
  # without resetting the deadline; a state change still arrives as
  # `{:run_updated, _}`, and the recheck timer backstops anything missed.
  defp wait_for_signal(deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      :recheck -> :recheck
      {:run_updated, run} -> {:run_updated, run}
      {:run_event, _event} -> wait_for_signal(deadline)
    after
      timeout -> :timeout
    end
  end

  defp schedule_recheck(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      Process.send_after(self(), :recheck, min(@recheck_interval_ms, remaining))
    end
  end

  defp runner_result_to_json({name, {:ok, :running, run}, runner}, subject) do
    fresh =
      case Runs.fetch_run_by_id(run.id, subject) do
        {:ok, r} -> r
        {:error, _} -> run
      end

    fresh
    |> full_run_payload(subject)
    |> Map.put(:runner, name)
    |> maybe_offline_warning(runner)
  end

  defp runner_result_to_json({name, {:ok, :pending_approval, run}, _runner}, _subject),
    do: %{
      runner: name,
      run_id: run.id,
      action_id: run.action_id,
      status: "pending_approval",
      waiting_on: "approval",
      policy: %{decision: run.policy_decision, reason: run.policy_reason},
      tip:
        "Operator approval required. Use the `wait_for_run` tool with run_id=#{run.id} to block until the decision."
    }

  defp runner_result_to_json({name, {:error, :denied_by_policy, reason}, _runner}, _subject),
    do: %{
      runner: name,
      status: "denied_by_policy",
      reason: reason,
      message:
        "Policy denied this call. The `reason` is the rule that fired; show it to the " <>
          "operator verbatim. If they want to bypass, they'd have to edit the policy " <>
          "(or get an approval grant for the same (action, runner, args) shape)."
    }

  defp runner_result_to_json({name, {:error, %Ecto.Changeset{} = changeset}, _runner}, _subject),
    do: %{
      runner: name,
      status: "error",
      error: "invalid_args",
      details: errors(changeset),
      message:
        "One or more arguments failed validation. `details` lists the offending fields " <>
          "and the reason — fix and retry."
    }

  defp runner_result_to_json({name, {:error, code}, _runner}, _subject) when is_atom(code),
    do: error_payload(name, code)

  defp runner_result_to_json({name, other, _runner}, _subject) do
    # Log the unknown term server-side for debugging, but never reflect the
    # internal shape back to the LLM/client — it could carry internal ids or
    # struct fields. Static message only.
    Logger.error("MCP dispatch: unrecognized runner result for #{name}: #{inspect(other)}")

    %{
      runner: name,
      status: "error",
      error: "unknown",
      message:
        "Unrecognized error from the cloud — the LLM can't recover from this on its own. " <>
          "Report it to Emisar support."
    }
  end

  defp maybe_offline_warning(payload, nil), do: payload

  defp maybe_offline_warning(payload, runner) do
    if runner.online? do
      payload
    else
      age =
        case runner.last_disconnected_at do
          nil -> "never connected"
          ts -> "last seen " <> human_ago(ts) <> " ago"
        end

      Map.merge(payload, %{
        warning: "runner_offline",
        warning_message:
          "Runner `#{runner.name}` is offline (#{age}). The run is queued and will " <>
            "deliver when it reconnects — tell the user, and offer to retry on a " <>
            "connected runner (see /runners) if they need it sooner."
      })
    end
  end

  defp error_payload(name, :reason_required),
    do: %{
      runner: name,
      status: "error",
      error: "reason_required",
      message:
        "Every action call must include a non-empty `reason` field — a short freeform " <>
          "sentence explaining why. It lands in the audit log so operators can later " <>
          "answer 'why did this fire?'."
    }

  defp error_payload(name, :runner_required),
    do: %{
      runner: name,
      status: "error",
      error: "runner_required",
      message:
        "This action runs on multiple runners. Pass `runners: [\"name\"]` in the body " <>
          "with one or more names from /tools."
    }

  defp error_payload(name, :runner_not_found),
    do: %{
      runner: name,
      status: "error",
      error: "runner_not_found",
      message:
        "The cloud couldn't resolve `#{name}` to a runner in this account. Re-fetch " <>
          "/runners to get the current name list."
    }

  defp error_payload(name, :action_not_found),
    do: %{
      runner: name,
      status: "error",
      error: "action_not_found",
      message:
        "Runner `#{name}` doesn't advertise this action. Either the runner needs the " <>
          "pack installed and the runner restarted (operator-side fix), or you should " <>
          "dispatch to a different runner that lists it in /tools."
    }

  defp error_payload(name, :action_required),
    do: %{
      runner: name,
      status: "error",
      error: "action_required",
      message: "The cloud didn't see an action_id in the call. This is a client-side bug."
    }

  defp error_payload(name, :runner_out_of_scope),
    do: %{
      runner: name,
      status: "error",
      error: "runner_out_of_scope",
      message:
        "Runner `#{name}` is outside the per-user runner scope of whoever minted this " <>
          "API key. Ask an admin to grant that user access to the runner on the team " <>
          "page, or mint a new key from a user that already has access."
    }

  defp error_payload(name, :pack_untrusted),
    do: %{
      runner: name,
      status: "error",
      error: "pack_untrusted",
      message:
        "Runner `#{name}` advertises a pack version no operator has trusted yet, so the cloud " <>
          "won't run it. A human must Trust the pack on the portal's Packs page — retrying or " <>
          "reloading tools will NOT clear this. Tell the user, and offer to retry once it's trusted."
    }

  defp error_payload(name, code),
    do: %{
      runner: name,
      status: "error",
      error: Atom.to_string(code),
      message:
        "Dispatch failed with `#{code}`. If this keeps happening, surface the code to " <>
          "the operator — it usually maps to an admin-side fix."
    }

  # -- Run payload (incl. output) -------------------------------------

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
      executed_command: run.executed_command,
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
    Enum.reduce(events, {"", ""}, fn event, {out, err} ->
      chunk = get_chunk(event)
      stream = event.stream || (event.payload && event.payload["stream"])

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

  defp unit_to_ms(""), do: 1000
  defp unit_to_ms("ms"), do: 1
  defp unit_to_ms("s"), do: 1000
  defp unit_to_ms("m"), do: 60_000
end

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
  alias EmisarWeb.Mcp.{Idempotency, ToolSchema}

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
    scopes = membership_scopes(api_key)

    runners =
      all_runners
      |> Enum.reject(& &1.disabled_at)
      |> Enum.filter(&runner_visible_to_key?(&1, api_key))
      |> Enum.filter(&Accounts.runner_in_scope?(&1, scopes))
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
    scopes = membership_scopes(api_key)

    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))

    visible_actions =
      actions
      |> Enum.filter(&action_visible_to_key?(&1, api_key, runners_by_id))
      |> Enum.filter(&action_in_membership_scope?(&1, runners_by_id, scopes))

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
    idempotency_key = Idempotency.resolve(conn, params)

    # Anything the LLM passes beyond the known top-level keys is an
    # action arg. `wait` is a query param but Phoenix merges query +
    # body into params, so it may land here too. `idempotency_key` is a
    # control field (Layer 2), not an action arg — drop it so it never
    # reaches the runner.
    action_args = Map.drop(params, ["action_id", "reason", "runners", "wait", "idempotency_key"])

    case resolve_runners(conn, api_key, action_id, runner_names) do
      {:ok, resolved} ->
        # Pre-fetch the runner rows once so the response can flag
        # offline / never-connected targets without N+1 lookups.
        runners_by_id = fetch_runners_by_id(conn, Enum.map(resolved, fn {_, id} -> id end))

        results =
          Enum.map(resolved, fn {name, runner_id} ->
            # When the caller is fanning out to N runners under ONE
            # Idempotency-Key, per-runner suffixes scope the key — the
            # unique index is `(api_key_id, idempotency_key)`, so two
            # runs from the same fan-out would otherwise collide.
            per_runner_key = Idempotency.per_runner(idempotency_key, runner_id)

            attrs = %{
              action_id: action_id,
              runner_id: runner_id,
              args: action_args,
              reason: reason,
              source: "mcp",
              api_key_id: api_key.id,
              idempotency_key: per_runner_key,
              # Per-user runner ACLs (#11): the key carries the operator's
              # membership at mint-time; dispatch_run resolves that
              # membership's runner scope at call-time. Revoking the
              # operator's scope immediately shrinks every key they minted.
              requested_by_membership_id: api_key.created_by_membership_id
            }

            result = Runs.dispatch_run(attrs, mcp_subject(conn))
            {name, result, Map.get(runners_by_id, runner_id)}
          end)

        respond_with_runs(conn, results, params["wait"])

      {:error, :runner_required, candidates} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "runner_required",
          message:
            "Multiple runners advertise this action. Pick one or more by name and " <>
              "retry with `runners: [\"name\"]` in the body. Call `/runners` first if " <>
              "you need to check which ones are online.",
          candidates: candidates
        })

      {:error, :runner_not_found, name} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "runner_not_found",
          runner: name,
          message:
            "No runner named `#{name}` exists in this account. Call `GET /api/mcp/runners` " <>
              "to see the actual names — they're case-sensitive and likely contain the " <>
              "environment / host (e.g. `db-prod-01`)."
        })

      {:error, :runner_not_allowed, name, why} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "runner_not_in_key_filter",
          runner: name,
          reason: why,
          message:
            "Runner `#{name}` exists, but this API key can't dispatch to it (#{why}). " <>
              "Either pick a runner from `GET /api/mcp/runners` (which only lists runners " <>
              "you can reach) or ask an admin to widen the key's scope on the API keys page."
        })

      {:error, :no_runner_available, :unknown_action} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "action_not_found",
          action_id: action_id,
          message:
            "No runner in this account advertises an action called `#{action_id}`. " <>
              "Call `/tools` to list every action the key can dispatch — the name has " <>
              "to match exactly (case-sensitive, including the `.` namespace)."
        })

      {:error, :no_runner_available, :scope_blocked} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "no_runner_in_scope",
          action_id: action_id,
          message:
            "The action `#{action_id}` exists, but no runner you can reach is currently " <>
              "advertising it. This usually means either (a) your API key's `runner_filter` " <>
              "or your user's runner scope excludes the runners that have it, or (b) the " <>
              "runners that have it are disabled. Ask an admin to grant access to one of " <>
              "the relevant runners on the team / API keys page."
        })

      {:error, :too_many_runners, max} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "too_many_runners",
          message:
            "Targeting more than #{max} runners in a single call isn't allowed. " <>
              "Split the work into batches of #{max} or fewer."
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
      [] ->
        # Disambiguate "the action_id is unknown anywhere in this account"
        # from "it exists, but every runner that has it is filtered out by
        # the caller's scope / key filter". The first lands as 404 +
        # `action_not_found`; the second as 403 + `no_runner_in_scope`,
        # so the LLM (and downstream operator) get distinct fixes.
        if action_exists_in_account?(conn, action_id),
          do: {:error, :no_runner_available, :scope_blocked},
          else: {:error, :no_runner_available, :unknown_action}

      [one] ->
        {:ok, [{one.name, one.id}]}

      candidates ->
        {:error, :runner_required, Enum.map(candidates, & &1.name)}
    end
  end

  defp resolve_runners(_conn, _api_key, _action_id, names) when length(names) > @max_runners_per_call,
    do: {:error, :too_many_runners, @max_runners_per_call}

  defp resolve_runners(conn, api_key, action_id, names) do
    allowed = allowed_runners_for_action(conn, api_key, action_id)
    {:ok, all, _} = Runners.list_runners_for_account(mcp_subject(conn))
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

  # When a named runner isn't in the allowed set, figure out exactly why
  # so the response can tell the LLM "your key is too narrow" vs "this
  # runner is disabled" vs "no runner of that name exists" — three very
  # different fixes the LLM should surface to its user.
  defp resolve_one(allowed, all, api_key, scopes, name) do
    case Enum.find(allowed, &(&1.name == name)) do
      %{id: id} ->
        {:ok, id}

      nil ->
        case Enum.find(all, &(&1.name == name)) do
          nil ->
            {:error, :runner_not_found, name}

          %Emisar.Runners.Runner{} = runner ->
            {:error, :runner_not_allowed, name, deny_reason(runner, api_key, scopes)}
        end
    end
  end

  # Reports the FIRST gate that rejects this runner. Order matches the
  # one the dispatch pipeline applies, so the message stays accurate
  # even if multiple gates would fail.
  defp deny_reason(runner, api_key, scopes) do
    cond do
      runner.disabled_at ->
        "runner is disabled"

      not runner_visible_to_key?(runner, api_key) ->
        "the API key's runner_filter / runner_group_filter doesn't include it"

      not Accounts.runner_in_scope?(runner, scopes) ->
        "the user who minted this key has no runner-scope grant for it"

      true ->
        "no advertised action with this name on this runner"
    end
  end

  # True iff ANY runner in this account currently advertises `action_id`.
  # Used to tell "you typed the action wrong" apart from "your scope
  # filters out every runner that has it" in the no-target dispatch
  # path.
  defp action_exists_in_account?(conn, action_id) do
    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))
    Enum.any?(actions, &(&1.action_id == action_id))
  end

  defp allowed_runners_for_action(conn, api_key, action_id) do
    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))

    runner_ids_advertising =
      actions
      |> Enum.filter(&(&1.action_id == action_id))
      |> Enum.map(& &1.runner_id)
      |> MapSet.new()

    {:ok, runners, _} = Runners.list_runners_for_account(mcp_subject(conn))
    scopes = membership_scopes(api_key)

    runners
    |> Enum.reject(& &1.disabled_at)
    |> Enum.filter(&(&1.id in runner_ids_advertising))
    |> Enum.filter(&runner_visible_to_key?(&1, api_key))
    |> Enum.filter(&Accounts.runner_in_scope?(&1, scopes))
  end

  # -- Tool descriptor + JSON Schema (draft 2020-12) ------------------

  defp mcp_tool_from_group([first | _] = group, runners_by_id) do
    runners =
      group
      |> Enum.map(&Map.get(runners_by_id, &1.runner_id))
      |> Enum.reject(&is_nil/1)
      # Sort connected runners first so the schema's enum lists usable
      # targets at the top — LLMs that don't read the description still
      # default to a sensible choice.
      |> Enum.sort_by(&{runner_status_rank(&1), &1.name})

    runner_names = runners |> Enum.map(& &1.name) |> Enum.uniq()

    %{
      name: first.action_id,
      description: tool_description(first, runners),
      inputSchema: ToolSchema.build(first, runner_names)
    }
  end

  # Connected runners come first (rank 0), then anything else.
  defp runner_status_rank(%{status: "connected"}), do: 0
  defp runner_status_rank(_), do: 1

  # Many LLMs treat the description as the canonical safety brief. Pack
  # everything the model needs into it: action intent, side effects,
  # per-runner status + last-heartbeat (so it won't queue against an
  # offline host without warning the user), risk label.
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
          lines = Enum.map_join(many, "\n", &("- " <> &1.name <> " (" <> runner_status_label(&1) <> ")"))
          "\n\nAvailable runners (pick one or more by name):\n" <> lines
      end

    base <> side_effects <> hosts <> "\n\nRisk: #{action.risk}"
  end

  # "connected" / "disconnected (last seen 5m ago)" / "pending (never connected)" —
  # one line per runner so the LLM can prefer online targets and warn
  # the user when an offline pick is the only option.
  defp runner_status_label(%{status: "connected"}), do: "connected"

  defp runner_status_label(%{status: "pending", last_heartbeat_at: nil}),
    do: "never connected"

  defp runner_status_label(%{status: status, last_heartbeat_at: ts}) when not is_nil(ts) do
    "#{status} (last seen " <> human_ago(ts) <> " ago)"
  end

  defp runner_status_label(%{status: status}), do: status

  # Compact "Nm" / "Nh" / "Nd" — enough granularity for the LLM to decide
  # whether to wait for a reconnect or pick a different runner. Uses
  # `DateTime.diff/3` so it stays correct across DST boundaries.
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

  # The key carries the minter's membership; the membership carries a
  # per-user runner scope (empty = all runners). Resolved fresh on every
  # call so revoking a scope is visible to all in-flight keys.
  defp membership_scopes(%{created_by_membership_id: nil}), do: []

  defp membership_scopes(%{created_by_membership_id: membership_id}),
    do: Accounts.runner_scopes_for_membership(membership_id)

  defp membership_scopes(_), do: []

  defp action_in_membership_scope?(_action, _runners_by_id, []), do: true

  defp action_in_membership_scope?(action, runners_by_id, scopes) do
    case Map.get(runners_by_id, action.runner_id) do
      %{} = runner -> Accounts.runner_in_scope?(runner, scopes)
      _ -> false
    end
  end

  defp group_actions_by_runner(conn) do
    {:ok, actions, _} = Catalog.list_actions_for_account(mcp_subject(conn))
    Enum.group_by(actions, & &1.runner_id)
  end

  # Returns `%{runner_id => %Runner{}}` for the supplied ids, restricted
  # to the caller's account. Used by `run_tool` to attach offline /
  # never-connected warnings to each successfully-queued run without an
  # N+1 hit per target.
  defp fetch_runners_by_id(conn, ids) when is_list(ids) do
    {:ok, all, _} = Runners.list_runners_for_account(mcp_subject(conn))
    Map.new(all, fn r -> {r.id, r} end) |> Map.take(ids)
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
      for {_name, {:ok, :running, %{id: id}}, _runner} <- results, do: id

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
  defp runner_result_to_json({name, {:ok, :running, run}, runner}, subject) do
    # Re-fetch in case the long-poll updated state.
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

  defp runner_result_to_json({name, {:ok, :pending_approval, run}, _runner}, _subject) do
    %{
      runner: name,
      run_id: run.id,
      status: "pending_approval",
      waiting_on: "approval",
      tip:
        "Operator approval required. Use the `wait_for_run` tool with run_id=#{run.id} to block until the decision."
    }
  end

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

  defp runner_result_to_json({name, {:error, %Ecto.Changeset{} = cs}, _runner}, _subject),
    do: %{
      runner: name,
      status: "error",
      error: "invalid_args",
      details: errors(cs),
      message:
        "One or more arguments failed validation. `details` lists the offending fields " <>
          "and the reason — fix and retry."
    }

  defp runner_result_to_json({name, {:error, code}, _runner}, _subject) when is_atom(code),
    do: error_payload(name, code)

  # Last-resort catchall — emits the term as text so logs still capture
  # the unknown shape, but with a clear instruction that this case
  # needs an Emisar-side fix rather than something the LLM can resolve.
  defp runner_result_to_json({name, other, _runner}, _subject),
    do: %{
      runner: name,
      status: "error",
      error: "unknown",
      details: inspect(other),
      message:
        "Unrecognized error from the cloud. Report the `details` string to Emisar support; " <>
          "the LLM can't recover from this on its own."
    }

  # A successfully-queued run against an offline runner sits in :pending
  # until the runner reconnects. Surface that so the LLM warns the user
  # before they start watching for output. We don't block dispatch —
  # short blips happen; the operator can decide whether to wait.
  defp maybe_offline_warning(payload, %{status: "connected"}), do: payload
  defp maybe_offline_warning(payload, nil), do: payload

  defp maybe_offline_warning(payload, %{status: status} = runner) do
    age =
      case runner.last_heartbeat_at do
        nil -> "never connected"
        ts -> "last seen " <> human_ago(ts) <> " ago"
      end

    Map.merge(payload, %{
      warning: "runner_offline",
      warning_message:
        "Runner `#{runner.name}` is #{status} (#{age}). The run is queued and will " <>
          "deliver when it reconnects — tell the user, and offer to retry on a " <>
          "connected runner (see /runners) if they need it sooner."
    })
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

  defp error_payload(name, code),
    do: %{
      runner: name,
      status: "error",
      error: Atom.to_string(code),
      message:
        "Dispatch failed with `#{code}`. If this keeps happening, surface the code to " <>
          "the operator — it usually maps to an admin-side fix."
    }

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

  defp mcp_subject(conn), do: conn.assigns.current_subject

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

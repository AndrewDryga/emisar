defmodule EmisarWeb.MCP.Service do
  @moduledoc """
  Shared business layer behind every MCP surface — the REST controller
  (`EmisarWeb.MCPController`) and the JSON-RPC controller
  (`EmisarWeb.MCPRpcController`).

  Returns plain data structures (lists, maps). Wrapping into HTTP /
  JSON-RPC envelopes is the caller's job.

  Every function takes a `conn` and reads `conn.assigns.api_key`
  + `conn.assigns.current_subject` (both set by the auth plug shared
  with MCPController). No DB access bypasses the existing context
  modules — `Catalog`, `Runners`, `Runs`.
  """

  alias Emisar.{Approvals, Catalog, Runbooks, Runners, Runs}
  alias EmisarWeb.MCP.{Cancellation, Idempotency, ToolMetadata, ToolSchema}
  require Logger

  # Same caps the REST handlers use; keep them in lockstep so
  # behavior matches whether the LLM hits /api/mcp/tools/:id or the
  # JSON-RPC equivalent.
  @max_runners_per_call 16
  @max_runner_target_bytes 512
  @max_wait_ms 60_000
  # Approval decisions commonly take longer than an action-result wait. Give the
  # dedicated `wait_for_run` tool one useful approval window; action dispatches
  # remain capped at 60s above so ordinary tool calls cannot hold a request as long.
  @max_get_run_wait_ms 300_000
  # The wait is event-driven — it blocks on the run's PubSub topic and wakes on
  # each `{:run_updated, _}` broadcast. This timer is only the safety net: a
  # missed broadcast, or a state change that doesn't broadcast at all, is still
  # caught within ~2s. ~10× fewer DB queries than the old 200ms busy-poll while
  # staying robust.
  @recheck_interval_ms 2_000

  @stdout_cap 65_536
  # A compromised runner can legally persist 256 KiB progress payloads. Limit
  # the number read for an MCP preview as well as each rendered stream so one
  # run cannot turn a status request into an unbounded database read.
  @max_output_events 32

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
    |> Enum.filter(&action_in_membership_scope?(&1, runners_by_id, scopes))
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
    |> Enum.filter(&Runners.runner_in_scope?(&1, scopes))
    |> Enum.map(fn runner ->
      %{
        id: runner.external_id,
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
  Published runbooks for the account — latest version per slug, as summary
  maps. An LLM discovers a runbook here, then either dispatches its steps
  itself (`get_runbook` resolves each step's runner target) or hands the whole
  runbook to `execute_runbook` to run it governed, end to end.
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

    # Reuse the context's slug-or-id published lookup instead of listing every
    # runbook and filtering in memory — same result, one indexed read.
    with {:ok, runbook} <- Runbooks.fetch_published_runbook(slug_or_id, subject),
         {:ok, runners} <- Runners.list_all_runners_for_account(subject) do
      {:ok, runbook_detail(runbook, runners)}
    end
  end

  defp published_latest_per_slug(runbooks) do
    runbooks
    |> Enum.filter(&(&1.status == :published))
    |> Enum.group_by(& &1.slug)
    |> Enum.map(fn {_slug, versions} -> Enum.max_by(versions, & &1.version) end)
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

  # -- Runbooks (execute + draft) -------------------------------------

  @doc """
  Execute a published runbook by slug or id through the governed
  `Runbooks.dispatch_runbook/4` path — every step flows through the same
  policy / approval / runner-scope / pack-trust / audit gates as a normal
  action dispatch. `reason` is required (audit "why"). Returns
  `{:ok, execution_payload}` or a `dispatch_runbook`/resolution error tuple.

  `idempotency_key` (Layer-2 tool arg over the Layer-1 transport header,
  resolved by the controller) makes a retried execute from the same API key
  return the ORIGINAL execution instead of double-running the runbook — the
  key rides through `dispatch_runbook` to the `(api_key_id, idempotency_key)`
  execution index. `nil` runs fresh.
  """
  @spec execute_runbook(Plug.Conn.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, atom() | tuple() | Ecto.Changeset.t()}
  def execute_runbook(conn, slug_or_id, reason, idempotency_key) do
    subject = conn.assigns.current_subject

    with :ok <- validate_reason(reason),
         {:ok, runbook} <- Runbooks.fetch_published_runbook(slug_or_id, subject),
         {:ok, result} <-
           Runbooks.dispatch_runbook(runbook, reason, subject, idempotency_key: idempotency_key) do
      {:ok, execution_payload(runbook, result, subject)}
    end
  end

  @doc """
  Create a DRAFT runbook from an LLM-proposed plan. Reuses the manage-gated
  `Runbooks.create_runbook/2` and its changeset validation; the status is never
  taken from the caller, so the row lands as a draft for an operator to review
  and publish — this call never publishes or dispatches. `params` carries
  `title` (required), optional `slug`/`description`, and `steps` (a list).
  Returns `{:ok, draft_payload}` or `{:error, %Ecto.Changeset{} | :unauthorized}`.
  """
  @spec create_runbook_draft(Plug.Conn.t(), map()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_runbook_draft(conn, params) do
    subject = conn.assigns.current_subject

    case Runbooks.create_runbook(draft_attrs(params), subject) do
      {:ok, runbook} -> {:ok, draft_payload(runbook, subject)}
      {:error, reason} -> {:error, reason}
    end
  end

  # `status` is deliberately omitted so the row defaults to :draft — an
  # LLM-authored runbook must never publish itself. Slug mirrors the editor:
  # a typed slug wins, otherwise derive it from the title.
  defp draft_attrs(params) do
    title = params["title"]

    %{
      "title" => title,
      "name" => title,
      "slug" => draft_slug(params["slug"], title),
      "description" => params["description"],
      "definition" => %{"steps" => params["steps"] || []}
    }
  end

  defp draft_slug(slug, _title) when is_binary(slug) and slug != "", do: slug
  defp draft_slug(_slug, title), do: Emisar.Slug.slugify(title, max_length: 79)

  defp draft_payload(runbook, subject) do
    %{
      runbook_id: runbook.id,
      slug: runbook.slug,
      title: runbook.title,
      version: runbook.version,
      status: runbook.status,
      review_url:
        "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runbooks/#{runbook.id}/edit"
    }
  end

  defp execution_payload(runbook, result, subject) do
    {:ok, runners} = Runners.list_all_runners_for_account(subject)
    names = Map.new(runners, &{&1.id, &1.name})

    %{
      runbook: %{slug: runbook.slug, title: runbook.title, version: runbook.version},
      runbook_execution_id: result.execution_id,
      total_step_runs: result.total,
      dispatched: Enum.map(result.runs, &execution_run_summary(&1, names)),
      errors: Enum.map(result.errors, &execution_error_summary(&1, names))
    }
  end

  defp execution_run_summary(run, names) do
    %{
      run_id: run.id,
      step_id: run.runbook_step_id,
      action_id: run.action_id,
      runner: Map.get(names, run.runner_id),
      status: run.status
    }
  end

  defp execution_error_summary(%{step_id: step_id, runner_id: runner_id, reason: reason}, names) do
    %{step_id: step_id, runner: Map.get(names, runner_id), error: execution_error_reason(reason)}
  end

  # A row-less dispatch failure's reason is an internal atom or changeset; expose
  # a stable string and never the struct (it can carry internal ids/fields).
  defp execution_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp execution_error_reason(_reason), do: "dispatch_failed"

  # -- Recent runs (read-only) ----------------------------------------

  @doc """
  The `recent_runs` synthetic tool: the calling agent's (or the whole
  account's) most recent runs, newest first, as compact summaries.
  """
  @spec recent_runs(
          Plug.Conn.t(),
          pos_integer(),
          :own | :account,
          String.t() | nil,
          String.t() | nil
        ) :: {:ok, [map()]} | {:error, :unauthorized | {:runner_not_found, String.t()}}
  def recent_runs(conn, limit, scope, runner, action) do
    subject = conn.assigns.current_subject

    with {:ok, runner_id} <- resolve_runner_filter(runner, subject),
         {:ok, runs, _meta} <-
           Runs.list_recent_runs(subject,
             scope: scope,
             limit: limit,
             runner_id: runner_id,
             action_id: action,
             preload: [:runner]
           ) do
      {:ok, Enum.map(runs, &run_summary/1)}
    end
  end

  # nil → no runner filter; a name resolves to its id (account-scoped) so the
  # agent can narrow to one host, or {:runner_not_found, name} for a clear miss.
  defp resolve_runner_filter(nil, _subject), do: {:ok, nil}

  defp resolve_runner_filter(name, subject) when is_binary(name) do
    case Runners.fetch_runner_by_name(name, subject) do
      {:ok, runner} -> {:ok, runner.id}
      {:error, :not_found} -> {:error, {:runner_not_found, name}}
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
          optional(:runner_targets) => term(),
          optional(:reason) => String.t() | nil,
          optional(:wait_ms) => non_neg_integer(),
          optional(:idempotency_key) => String.t() | nil,
          optional(:mcp_session_id) => String.t() | nil,
          optional(:attestation) => map() | nil | :invalid
        }

  @type dispatch_error ::
          {:error, :reason_required}
          | {:error, :runner_required, [String.t()]}
          | {:error, :invalid_runner_targets}
          | {:error, :duplicate_runners}
          | {:error, :runner_not_found, String.t()}
          | {:error, :runner_not_allowed, String.t(), String.t()}
          | {:error, :invalid_attestation}
          | {:error, :attestation_targets_mismatch}
          | {:error, :cancelled}
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

    runner_targets = Map.get(opts, :runner_targets, [])
    reason = Map.get(opts, :reason)
    idempotency_key = Map.get(opts, :idempotency_key)
    wait_ms = Map.get(opts, :wait_ms, 0)
    mcp_session_id = Map.get(opts, :mcp_session_id)
    attestation = Map.get(opts, :attestation)

    with :ok <- validate_reason(reason),
         {:ok, resolved} <- resolve_runners(subject, api_key, action_id, runner_targets),
         :ok <- validate_attestation_targets(attestation, resolved) do
      runners_by_id = fetch_runners_by_id(subject, Enum.map(resolved, fn {_, id, _} -> id end))

      results =
        Enum.map(resolved, fn {name, runner_id, _external_id} ->
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
            attestation: attestation,
            idempotency_key: per_runner_key,
            requested_by_membership_id: api_key.created_by_membership_id
          }

          result = Runs.dispatch_run(attrs, subject)
          {name, result, Map.get(runners_by_id, runner_id)}
        end)

      case maybe_poll_to_terminal(subject, results, wait_ms, Cancellation.topic(conn)) do
        :ok -> {:ok, Enum.map(results, &runner_result_to_json(&1, subject))}
        :cancelled -> {:error, :cancelled}
      end
    end
  end

  @doc "Dispatches a preflighted fixed-catalog action and returns current run summaries."
  def dispatch_fixed_action(conn, targets, intent, wait_ms) do
    api_key = conn.assigns.api_key
    subject = conn.assigns.current_subject

    operation_attrs = %{
      operation_id: intent.operation_id,
      tool: :run_action,
      fingerprint: intent.fingerprint,
      action_id: intent.action_id,
      pack_ref: intent.pack_ref
    }

    target_attrs =
      Enum.map(targets, fn target ->
        %{
          action_id: intent.action_id,
          runner_id: target.id,
          args: intent.args,
          args_raw: intent.args_raw,
          reason: intent.reason,
          source: "mcp",
          api_key_id: api_key.id,
          client_info: api_key.last_client_info || %{},
          mcp_session_id: request_session_id(conn),
          attestation: intent.attestation,
          idempotency_key: Idempotency.per_runner(intent.operation_id, target.id),
          operation_id: intent.operation_id,
          pack_ref: intent.pack_ref,
          requested_by_membership_id: api_key.created_by_membership_id
        }
      end)

    with {:ok, runs} <- Runs.dispatch_mcp_fanout(operation_attrs, target_attrs, subject),
         true <- complete_target_set?(runs, targets),
         :ok <-
           maybe_poll_to_terminal(
             subject,
             fixed_dispatch_results(runs, targets),
             wait_ms,
             Cancellation.topic(conn)
           ),
         {:ok, runs} <-
           Runs.list_runs_by_mcp_operation(hd(runs).mcp_operation_record_id, subject),
         true <- complete_target_set?(runs, targets) do
      {:ok, fixed_run_summaries(runs, subject)}
    else
      :cancelled -> {:error, :cancelled}
      false -> {:error, :operation_incomplete}
      other -> other
    end
  end

  defp fixed_dispatch_results(runs, targets) do
    targets_by_id = Map.new(targets, &{&1.id, &1})

    Enum.map(runs, fn run ->
      target = Map.fetch!(targets_by_id, run.runner_id)
      {target.name, fixed_dispatch_result(run), target}
    end)
  end

  defp fixed_dispatch_result(%{status: :denied, policy_reason: reason}),
    do: {:error, :denied_by_policy, reason || "policy denied this call"}

  defp fixed_dispatch_result(%{status: :pending_approval} = run),
    do: {:ok, :pending_approval, run}

  defp fixed_dispatch_result(run), do: {:ok, :running, run}

  defp complete_target_set?(runs, targets) do
    MapSet.new(runs, & &1.runner_id) == MapSet.new(targets, & &1.id)
  end

  @doc "Renders fixed-contract run summaries within one 64 KiB output-preview budget."
  def fixed_run_summaries(runs, subject) when is_list(runs) do
    stream_cap = min(16_384, div(65_536, max(2 * length(runs), 1)))
    Enum.map(runs, &fixed_run_summary(&1, subject, stream_cap))
  end

  @doc "Renders one fixed-contract run summary."
  def fixed_run_summary(run, subject, stream_cap \\ 16_384) do
    details = full_run_payload(run, subject, stream_cap)
    {approval, approval_wait_until} = fixed_approval(run, subject)

    %{
      run_id: run.id,
      operation_id: run.operation_id,
      action_id: run.action_id,
      pack_ref: run.pack_ref,
      runner_ref: run.runner_ref,
      runbook_execution_id: run.runbook_execution_id,
      step_id: run.runbook_step_id,
      status: to_string(run.status),
      created_at: run.inserted_at,
      finished_at: run.finished_at,
      exit_code: run.exit_code,
      duration_ms: run.duration_ms,
      stdout: details.stdout,
      stderr: details.stderr,
      stdout_bytes: run.stdout_bytes,
      stderr_bytes: run.stderr_bytes,
      stdout_sha256: run.stdout_sha256,
      stderr_sha256: run.stderr_sha256,
      truncated_stdout:
        output_truncated?(
          details.stdout,
          run.stdout_bytes,
          details.stdout_truncated,
          details.output_events_truncated
        ),
      truncated_stderr:
        output_truncated?(
          details.stderr,
          run.stderr_bytes,
          details.stderr_truncated,
          details.output_events_truncated
        ),
      approval: approval,
      wait_until: approval_wait_until || fixed_wait_until(run),
      next: fixed_run_next(run),
      run_url: "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runs/#{run.id}"
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp output_truncated?(preview, total_bytes, locally_truncated?, events_truncated?) do
    locally_truncated? or events_truncated? or
      (is_integer(total_bytes) and total_bytes > byte_size(preview))
  end

  defp fixed_approval(%{status: :pending_approval} = run, subject) do
    case Approvals.fetch_request_for_visible_run(run, subject) do
      {:ok, request} ->
        approval = %{
          request_id: request.id,
          url: "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/approvals/#{request.id}",
          expires_at: request.expires_at
        }

        {approval, request.expires_at}

      _ ->
        {nil, nil}
    end
  end

  defp fixed_approval(_run, _subject), do: {nil, nil}

  # DispatchTimeout gives an acknowledged-or-terminal decision ten minutes
  # after queueing. Expose that durable deadline rather than inventing a wait
  # horizon from this particular HTTP request.
  defp fixed_wait_until(%{status: :sent, queued_at: %DateTime{} = queued_at}),
    do: DateTime.add(queued_at, 600, :second)

  defp fixed_wait_until(_run), do: nil

  defp fixed_run_next(%{status: status, id: run_id}) do
    if Runs.ActionRun.terminal?(status),
      do: nil,
      else: %{tool: "wait_for_run", arguments: %{run_id: run_id, timeout: "5m"}}
  end

  defp request_session_id(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [session_id | _] when session_id != "" -> session_id
      _ -> nil
    end
  end

  # -- Run fetch + long-poll ------------------------------------------

  @doc """
  Single run state, with optional long-poll until terminal. `wait_ms`
  is clamped to five minutes. Returns `{:ok, payload, status}` where status
  is `:terminal` or `:waiting` so the caller can choose a 200 vs 202.
  """
  @spec fetch_run(Plug.Conn.t(), String.t(), non_neg_integer()) ::
          {:ok, map(), :terminal | :waiting} | {:error, :cancelled | :not_found | :invalid_wait}
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

          case poll_to_terminal(subject, run.id, deadline, Cancellation.topic(conn)) do
            {:terminal, final} ->
              {:ok, full_run_payload(final, subject), :terminal}

            :cancelled ->
              {:error, :cancelled}

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

  # `reason` is the audit "why" — a security product requires it on every
  # dispatch. The tool schema declares it required, but a schema is an LLM hint,
  # not the gate; enforce it here so an absent/blank reason fails closed rather
  # than persisting a run with no rationale for the operator to audit.
  defp validate_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, :reason_required}, else: :ok
  end

  defp validate_reason(_), do: {:error, :reason_required}

  # -- Runner resolution ----------------------------------------------

  defp resolve_runners(subject, api_key, action_id, []) do
    case allowed_runners_for_action(subject, api_key, action_id) do
      [] ->
        if action_exists_in_account?(subject, action_id),
          do: {:error, :no_runner_available, :scope_blocked},
          else: {:error, :no_runner_available, :unknown_action}

      # `runners` is always required — emisar never auto-targets, even when
      # exactly one runner advertises the action. Absent/empty `runners` fails
      # closed with candidate durable ids so the caller selects the host
      # explicitly (audit-visible intent; no silent retarget as the fleet shifts).
      candidates ->
        {:error, :runner_required, Enum.map(candidates, & &1.external_id)}
    end
  end

  defp resolve_runners(_subject, _api_key, _action_id, targets) when not is_list(targets),
    do: {:error, :invalid_runner_targets}

  defp resolve_runners(subject, api_key, action_id, targets) do
    cond do
      Enum.any?(targets, &(not valid_runner_target?(&1))) ->
        {:error, :invalid_runner_targets}

      length(targets) > @max_runners_per_call ->
        {:error, :too_many_runners, @max_runners_per_call}

      MapSet.size(MapSet.new(targets)) != length(targets) ->
        {:error, :duplicate_runners}

      true ->
        resolve_target_runners(subject, api_key, action_id, targets)
    end
  end

  defp valid_runner_target?(target),
    do: is_binary(target) and target != "" and byte_size(target) <= @max_runner_target_bytes

  defp resolve_target_runners(subject, api_key, action_id, targets) do
    allowed = allowed_runners_for_action(subject, api_key, action_id)
    {:ok, all} = Runners.list_all_runners_for_account(subject)
    scopes = membership_scopes(api_key)

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case resolve_one(allowed, all, api_key, scopes, target) do
        {:ok, runner} ->
          {:cont, {:ok, [{runner.name, runner.id, runner.external_id} | acc]}}

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> unique_resolved_runners(Enum.reverse(list))
      err -> err
    end
  end

  defp unique_resolved_runners(runners) do
    runner_ids = Enum.map(runners, fn {_name, runner_id, _external_id} -> runner_id end)

    if MapSet.size(MapSet.new(runner_ids)) == length(runner_ids),
      do: {:ok, runners},
      else: {:error, :duplicate_runners}
  end

  # MCP tool schemas use the runner's durable external id because an enforcing
  # runner can verify that identity locally. Display-name matching remains for
  # unsigned older/direct callers, but a signed call is rejected below unless
  # its target set equals the resolved external ids.
  defp resolve_one(allowed, all, api_key, scopes, target) do
    case find_runner(allowed, target) do
      %_{} = runner ->
        {:ok, runner}

      nil ->
        case find_runner(all, target) do
          nil ->
            {:error, :runner_not_found, target}

          %_{} = runner ->
            {:error, :runner_not_allowed, target, deny_reason(runner, api_key, scopes)}
        end
    end
  end

  # Prefer the security identity over the display alias across the whole set.
  # A name may legally equal a different runner's external id; that ambiguity
  # must not turn an exact-id selection into a name match on list order.
  defp find_runner(runners, target) do
    Enum.find(runners, &(&1.external_id == target)) || Enum.find(runners, &(&1.name == target))
  end

  defp validate_attestation_targets(nil, _resolved), do: :ok

  defp validate_attestation_targets(:invalid, _resolved),
    do: {:error, :invalid_attestation}

  defp validate_attestation_targets(%{"targets" => targets}, resolved) do
    expected =
      resolved |> Enum.map(fn {_name, _id, external_id} -> external_id end) |> Enum.sort()

    if Enum.sort(targets) == expected, do: :ok, else: {:error, :attestation_targets_mismatch}
  end

  defp validate_attestation_targets(_attestation, _resolved),
    do: {:error, :invalid_attestation}

  defp deny_reason(runner, _api_key, scopes) do
    cond do
      runner.disabled_at ->
        "runner is disabled"

      not Runners.runner_in_scope?(runner, scopes) ->
        "the operator who minted this key has no runner-scope grant for it"

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
    |> Enum.filter(&(&1.id in runner_ids_advertising and Runners.runner_in_scope?(&1, scopes)))
  end

  defp fetch_runners_by_id(subject, ids) do
    {:ok, all} = Runners.list_all_runners_for_account(subject)
    Map.new(all, fn r -> {r.id, r} end) |> Map.take(ids)
  end

  # -- Tool descriptor builder ----------------------------------------

  defp mcp_tool_from_group(group, runners_by_id) do
    # Sort the per-runner variants by runner_id so the representative `first` —
    # and thus the description + arg schema the descriptor advertises — is
    # byte-stable across rebuilds regardless of the incoming group's order (the
    # byte-stable tool-metadata goal). The tool name is the shared action_id, so
    # ordering never changes it.
    group = Enum.sort_by(group, & &1.runner_id)
    [first | _] = group

    runners =
      group
      |> Enum.map(&Map.get(runners_by_id, &1.runner_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{runner_status_rank(&1), &1.name})

    runner_targets =
      runners
      |> Enum.map(&%{id: &1.external_id, name: &1.name})
      |> Enum.uniq_by(& &1.id)

    %{
      name: first.action_id,
      title: ToolMetadata.group_title(group),
      description: tool_description(group, runners),
      inputSchema: group_input_schema(group, runner_targets),
      annotations: ToolMetadata.group_annotations(group)
    }
    |> ToolMetadata.auth_required()
  end

  defp runner_status_rank(runner), do: if(runner.online?, do: 0, else: 1)

  # Identical arg schemas across the group → describe them precisely. When
  # they diverge, fall back to the control-fields-only descriptor rather
  # than advertising one arbitrary runner's arg contract for all of them.
  defp group_input_schema([first | _] = group, runner_targets) do
    if uniform?(group, & &1.args_schema),
      do: ToolSchema.build(first, runner_targets),
      else: ToolSchema.build_ambiguous(runner_targets)
  end

  defp uniform?(group, fun), do: group |> Enum.map(fun) |> Enum.uniq() |> length() == 1

  defp tool_description([first | _] = group, runners) do
    base = first.description || first.title || first.action_id

    combined_side_effects = group |> Enum.flat_map(&(&1.side_effects || [])) |> Enum.uniq()

    side_effects =
      case combined_side_effects do
        [] -> ""
        list -> "\n\nSide effects:\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    hosts =
      case runners do
        [] ->
          ""

        [only] ->
          "\n\nRuns on: #{only.name} — #{only.external_id} (#{runner_status_label(only)})"

        many ->
          lines =
            Enum.map_join(
              many,
              "\n",
              &("- " <>
                  &1.name <>
                  " — " <> &1.external_id <> " (" <> runner_status_label(&1) <> ")")
            )

          "\n\nAvailable runners (select one or more by stable id):\n" <> lines
      end

    risk_line = "\n\nRisk: #{ToolMetadata.worst_risk(group)}"
    base <> side_effects <> hosts <> variant_note(group) <> risk_line
  end

  # When runners disagree on this action's risk or arguments, say so: the
  # descriptor shows the worst case, and the runner the caller picks
  # enforces its own spec on dispatch. Cosmetic drift (title/description)
  # is not flagged — only the two divergences that change what runs.
  defp variant_note(group) do
    cond do
      not uniform?(group, & &1.risk) ->
        "\n\nNote: runners advertise different risk levels for this action; the value below " <>
          "is the highest. The runner you select enforces its own risk and arguments."

      not uniform?(group, & &1.args_schema) ->
        "\n\nNote: runners advertise different arguments for this action; pass what your " <>
          "chosen runner requires — it re-validates on dispatch."

      true ->
        ""
    end
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
  # An MCP key sees + reaches exactly the runners the MINTING OPERATOR can —
  # their `UserRunnerScope` (`membership_scopes`), resolved at call time. The
  # key carries no per-key runner filter of its own.

  defp membership_scopes(%{created_by_membership_id: id}) when is_binary(id),
    do: Runners.runner_scopes_for_membership(id)

  defp membership_scopes(_), do: nil

  defp action_in_membership_scope?(_action, _runners_by_id, []), do: true

  defp action_in_membership_scope?(action, runners_by_id, scopes) do
    case Map.get(runners_by_id, action.runner_id) do
      %{} = runner -> Runners.runner_in_scope?(runner, scopes)
      _ -> false
    end
  end

  # -- Per-runner long-poll + result rendering ------------------------

  defp maybe_poll_to_terminal(_subject, _results, 0, _cancellation_topic), do: :ok

  defp maybe_poll_to_terminal(subject, results, ms, cancellation_topic) do
    polling_ids =
      for {_name, {:ok, :running, %{id: id}}, _runner} <- results, do: id

    if polling_ids == [] do
      :ok
    else
      deadline = System.monotonic_time(:millisecond) + ms
      poll_all_to_terminal(subject, polling_ids, deadline, cancellation_topic)
    end
  end

  # Block until every run in `ids` is terminal or the deadline passes. The
  # runner socket broadcasts `{:run_updated, _}` on each run's topic at every
  # state transition (Runs broadcasts on the run topic), so we subscribe and wake
  # on those instead of busy-polling; the recheck timer is the safety net.
  defp poll_all_to_terminal(subject, ids, deadline, cancellation_topic) do
    Enum.each(ids, &Runs.subscribe_run(subject.account.id, &1))
    schedule_recheck(deadline)

    try do
      await_all_terminal(subject, ids, deadline, cancellation_topic)
    after
      Enum.each(ids, &Runs.unsubscribe_run(subject.account.id, &1))
    end
  end

  defp await_all_terminal(subject, ids, deadline, cancellation_topic) do
    remaining = Enum.reject(ids, &run_terminal?(&1, subject))

    if remaining == [] do
      :ok
    else
      case wait_for_signal(deadline, cancellation_topic) do
        :recheck ->
          schedule_recheck(deadline)
          await_all_terminal(subject, remaining, deadline, cancellation_topic)

        {:run_updated, _run} ->
          await_all_terminal(subject, remaining, deadline, cancellation_topic)

        :cancelled ->
          :cancelled

        :timeout ->
          :ok
      end
    end
  end

  defp run_terminal?(run_id, subject) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:ok, %{status: status}} -> Runs.ActionRun.terminal?(status)
      _ -> false
    end
  end

  defp run_status_kind(%{status: status}) do
    if Runs.ActionRun.terminal?(status), do: :terminal, else: :waiting
  end

  # Single-run variant of the above, returning the terminal run for the caller
  # to render. Same event-driven wait; one subscription instead of N.
  defp poll_to_terminal(subject, run_id, deadline, cancellation_topic) do
    Runs.subscribe_run(subject.account.id, run_id)
    schedule_recheck(deadline)

    try do
      await_terminal(subject, run_id, deadline, cancellation_topic)
    after
      Runs.unsubscribe_run(subject.account.id, run_id)
    end
  end

  defp await_terminal(subject, run_id, deadline, cancellation_topic) do
    case Runs.fetch_run_by_id(run_id, subject) do
      {:error, :not_found} ->
        :timeout

      {:ok, %{status: status} = run} ->
        if Runs.ActionRun.terminal?(status) do
          {:terminal, run}
        else
          case wait_for_signal(deadline, cancellation_topic) do
            :recheck ->
              schedule_recheck(deadline)
              await_terminal(subject, run_id, deadline, cancellation_topic)

            {:run_updated, _run} ->
              await_terminal(subject, run_id, deadline, cancellation_topic)

            :cancelled ->
              :cancelled

            :timeout ->
              :timeout
          end
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
  defp wait_for_signal(deadline, cancellation_topic) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      :recheck ->
        :recheck

      {:run_updated, run} ->
        {:run_updated, run}

      {:run_event, _event} ->
        wait_for_signal(deadline, cancellation_topic)

      {:mcp_request_cancelled, ^cancellation_topic} when is_binary(cancellation_topic) ->
        :cancelled
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
        "This action needs an explicit target. Pass `runners: [\"stable-id\"]` in the body " <>
          "with one or more ids from the tool schema."
    }

  defp error_payload(name, :runner_not_found),
    do: %{
      runner: name,
      status: "error",
      error: "runner_not_found",
      message:
        "The cloud couldn't resolve `#{name}` to a runner in this account. Re-fetch " <>
          "/runners to get the current stable ids and display names."
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

  defp error_payload(name, :pack_retired),
    do: %{
      runner: name,
      status: "error",
      error: "pack_retired",
      message:
        "Runner `#{name}` advertises a pack version that a newer release RETIRED (a critical " <>
          "fix superseded it), so the cloud won't run it. Update the pack on the runner " <>
          "(`emisar pack install <pack>`), or an admin can re-trust this exact version on the " <>
          "portal's Packs page. Retrying will NOT clear this — tell the user."
    }

  defp error_payload(name, :runner_requires_attestation),
    do: %{
      runner: name,
      status: "error",
      error: "runner_requires_attestation",
      message:
        "Runner `#{name}` only runs signed dispatches, and this call carried no signature. " <>
          "The MCP client must be configured with the runner's signing key so it can sign " <>
          "the call. Tell the operator — this is a client-side setup, not a retry."
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

  defp full_run_payload(run, subject, stream_cap \\ @stdout_cap) do
    {:ok, events} = Runs.list_recent_events_for_run(run.id, @max_output_events + 1, subject)
    {events, output_events_truncated?} = output_tail(events)

    {{stdout, stdout_truncated?}, {stderr, stderr_truncated?}} =
      collect_streams(events, stream_cap)

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
      stdout: stdout,
      stderr: stderr,
      stdout_truncated: stdout_truncated?,
      stderr_truncated: stderr_truncated?,
      output_events_truncated: output_events_truncated?,
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

  defp output_tail(events) when length(events) > @max_output_events,
    do: {tl(events), true}

  defp output_tail(events), do: {events, false}

  defp collect_streams(events, stream_cap) do
    Enum.reduce(events, {{"", false}, {"", false}}, fn event, {out, err} ->
      chunk = get_chunk(event)
      stream = event.stream || (event.payload && event.payload["stream"])

      case stream do
        "stderr" -> {out, append_tail(err, chunk, stream_cap)}
        _ -> {append_tail(out, chunk, stream_cap), err}
      end
    end)
  end

  defp append_tail({output, truncated?}, chunk, cap) do
    combined = output <> chunk
    {truncate(combined, cap), truncated? or byte_size(combined) > cap}
  end

  defp get_chunk(%{payload: %{"chunk" => c}}) when is_binary(c), do: c
  defp get_chunk(_), do: ""

  defp truncate(s, n) when byte_size(s) <= n, do: s

  defp truncate(s, n) do
    s
    |> binary_part(byte_size(s) - n, n)
    |> drop_incomplete_utf8_prefix(0)
  end

  defp drop_incomplete_utf8_prefix(value, dropped) when dropped < 4 do
    if String.valid?(value),
      do: value,
      else: drop_incomplete_utf8_prefix(tl_binary(value), dropped + 1)
  end

  defp drop_incomplete_utf8_prefix(_value, _dropped), do: ""
  defp tl_binary(<<_byte, rest::binary>>), do: rest
  defp tl_binary(<<>>), do: <<>>

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

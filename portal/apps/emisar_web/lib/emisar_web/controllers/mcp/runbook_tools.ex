defmodule EmisarWeb.MCP.RunbookTools do
  @moduledoc """
  Fixed MCP runbook discovery, draft creation, and execution boundary.

  Public refs are translated once at this boundary. The Runbooks context owns
  immutable versions, authorization, frozen work lists, wave dispatch, and audit.
  """

  alias Emisar.{Catalog, Crypto, MCPOperations, Runbooks, Runners, Runs, Slug}
  alias EmisarWeb.MCP.{ActionContract, CatalogCursor, ResponseBudget, RunbookContract}
  alias EmisarWeb.MCP.ValidationError

  @runbook_ref ~r/\A([a-z][a-z0-9_-]{0,79})@([1-9][0-9]*)\z/
  @default_limit 15

  @doc "Executes one of the four fixed runbook tools."
  def call(conn, "list_runbooks", args, _operation_id), do: list_runbooks(conn, args)
  def call(conn, "get_runbook", args, _operation_id), do: get_runbook(conn, args)

  def call(conn, "execute_runbook", args, operation_id),
    do: execute_runbook(conn, args, operation_id)

  def call(conn, "create_runbook_draft", args, operation_id),
    do: create_draft(conn, args, operation_id)

  defp list_runbooks(conn, args) do
    query = args["query"]
    limit = args["limit"] || @default_limit

    with {:ok, snapshot} <- catalog_snapshot(conn),
         {:ok, summaries} <- published_summaries(conn, query, snapshot),
         scope <- cursor_scope(conn),
         filters <- %{"query" => query, "limit" => limit},
         {:ok, after_key} <-
           CatalogCursor.decode(args["cursor"], "list_runbooks", scope, filters) do
      page = drop_through(summaries, after_key) |> Enum.take(limit + 1)
      {items, more?} = split_more(page, limit)
      observed_at = DateTime.utc_now()

      {:ok, fit_runbook_page(items, more?, observed_at, scope, filters)}
    else
      {:error, :invalid_cursor} ->
        {:error,
         error("invalid_cursor", "The cursor is invalid, expired, or belongs to another query.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read runbooks.")}
    end
  end

  defp get_runbook(conn, args) do
    # Schema-validated: runbook_ref always matches the published pattern.
    {:ok, {slug, version}} = parse_runbook_ref(args["runbook_ref"])

    with {:ok, runbook} <-
           Runbooks.fetch_published_runbook_version(slug, version, conn.assigns.current_subject),
         {:ok, snapshot} <- catalog_snapshot(conn),
         {:ok, public_runbook} <- RunbookContract.project(runbook, snapshot) do
      {:ok, %{ok: true, runbook: public_runbook}}
    else
      {:error, :not_found} ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read runbooks.")}

      {:error, :incomplete_contract} ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}
    end
  end

  defp create_draft(conn, args, operation_id) do
    with {:ok, input} <- validate_draft(args) do
      fingerprint = mutation_fingerprint("create_runbook_draft", draft_facts(input))
      operation_attrs = draft_operation_attrs(input, operation_id, fingerprint, conn)

      case create_or_replay_draft(conn, input, operation_attrs) do
        {:ok, _kind, runbook} ->
          {:ok, draft_payload(runbook, operation_id, conn.assigns.current_subject)}

        {:error, :operation_conflict} ->
          {:error,
           error("operation_conflict", "This operation_id already belongs to another mutation.")}

        {:error, :operation_incomplete} ->
          {:error,
           error(
             "operation_incomplete",
             "The operation committed without its draft resource.",
             true,
             %{operation_id: operation_id}
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error,
           error("invalid_runbook", "The draft failed validation.", false, %{
             fields: changeset_errors(changeset)
           })}

        {:error, :unauthorized} ->
          {:error, error("not_allowed", "This key cannot create runbook drafts.")}

        {:error, %{} = payload} ->
          {:error, payload}
      end
    end
  end

  defp create_or_replay_draft(conn, input, operation_attrs) do
    subject = conn.assigns.current_subject

    case MCPOperations.fetch_matching_replay(operation_attrs, subject) do
      {:ok, _operation} ->
        case Runbooks.fetch_mcp_draft_by_operation(operation_attrs.operation_id, subject) do
          {:ok, runbook} -> {:ok, :replay, runbook}
          {:error, :not_found} -> {:error, :operation_incomplete}
          other -> other
        end

      {:error, :not_found} ->
        with {:ok, snapshot} <- catalog_snapshot(conn),
             {:ok, steps} <- normalize_draft_steps(input.steps, snapshot) do
          attrs = draft_attrs(input, steps)

          Runbooks.create_mcp_draft(
            attrs,
            operation_attrs.operation_id,
            operation_attrs.fingerprint,
            subject
          )
        end

      other ->
        other
    end
  end

  defp execute_runbook(conn, args, operation_id) do
    input = %{runbook_ref: args["runbook_ref"], reason: args["reason"]}

    fingerprint =
      mutation_fingerprint("execute_runbook", %{
        "runbook_ref" => input.runbook_ref,
        "reason" => input.reason
      })

    operation_attrs = execution_operation_attrs(input, operation_id, fingerprint, conn)

    with {:ok, execution, runbook} <- execute_or_replay(conn, input, operation_attrs),
         {:ok, payload} <- execution_payload(conn, execution, runbook) do
      {:ok, %{ok: true, operation_id: operation_id, execution: payload}}
    else
      {:error, :operation_conflict} ->
        {:error,
         error("operation_conflict", "This operation_id already belongs to another mutation.")}

      {:error, :operation_incomplete} ->
        {:error,
         error(
           "operation_incomplete",
           "The operation committed without its execution resource.",
           true,
           %{operation_id: operation_id}
         )}

      {:error, :signed_runbook_unsupported} ->
        {:error,
         error(
           "signed_runbook_unsupported",
           "A runbook cannot execute on a signed-only runner because the bridge signs only direct run_action calls."
         )}

      {:error, :target_contract_changed} ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}

      {:error, :incomplete_contract} ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}

      {:error, :not_found} ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot execute this runbook.")}

      {:error, reason} ->
        {:error, error("execution_failed", execution_error(reason))}
    end
  end

  defp execute_or_replay(conn, input, operation_attrs) do
    subject = conn.assigns.current_subject

    case MCPOperations.fetch_matching_replay(operation_attrs, subject) do
      {:ok, _operation} ->
        fetch_committed_execution(operation_attrs.operation_id, subject)

      {:error, :not_found} ->
        execute_new(conn, input, operation_attrs)

      other ->
        other
    end
  end

  defp execute_new(conn, input, operation_attrs) do
    subject = conn.assigns.current_subject

    with {:ok, {slug, version}} <- parse_runbook_ref(input.runbook_ref),
         {:ok, runbook} <- Runbooks.fetch_published_runbook_version(slug, version, subject),
         :ok <- preflight_runbook(conn, runbook),
         {:ok, _result} <-
           Runbooks.dispatch_runbook(runbook, input.reason, subject,
             operation_id: operation_attrs.operation_id,
             operation_fingerprint: operation_attrs.fingerprint,
             operation_ref: input.runbook_ref,
             max_runners_per_step: 16,
             max_fan_out: 256
           ) do
      fetch_committed_execution(operation_attrs.operation_id, subject)
    end
  end

  defp fetch_committed_execution(operation_id, subject) do
    with {:ok, execution} <- Runbooks.fetch_execution_by_operation(operation_id, subject),
         {:ok, runbook} <- Runbooks.fetch_runbook_for_execution(execution, subject) do
      {:ok, execution, runbook}
    else
      {:error, :not_found} -> {:error, :operation_incomplete}
      other -> other
    end
  end

  @doc "Builds the fixed execution projection used by execute, wait, and recovery."
  def execution_payload(conn, execution, runbook) do
    subject = conn.assigns.current_subject

    with {:ok, runs} <- Runs.list_runs_by_runbook_execution(execution.id, subject) do
      execution_payload_from_runs(execution, runbook, runs)
    end
  end

  @doc "Builds the fixed execution projection from an already authorized run list."
  def execution_payload_from_runs(execution, runbook, runs) when is_list(runs) do
    status = execution_status(execution, runs)

    {:ok,
     %{
       runbook_execution_id: execution.id,
       runbook_ref: runbook_ref(runbook),
       status: status,
       steps: execution_steps(runbook, execution, runs),
       runs_next: %{
         tool: "recent_runs",
         arguments: %{runbook_execution_id: execution.id, limit: 15}
       }
     }
     |> maybe_put(
       :next,
       if(status in ~w(pending running pending_approval),
         do: %{
           tool: "wait_for_run",
           arguments: %{runbook_execution_id: execution.id, timeout: "60s"}
         }
       )
     )}
  end

  defp published_summaries(conn, query, snapshot) do
    case Runbooks.list_all_runbooks(conn.assigns.current_subject) do
      {:ok, runbooks} ->
        summaries =
          runbooks
          |> Enum.filter(&(&1.status == :published))
          |> Enum.group_by(& &1.slug)
          |> Enum.map(fn {_slug, versions} -> Enum.max_by(versions, & &1.version) end)
          |> Enum.flat_map(fn runbook ->
            case RunbookContract.project(runbook, snapshot) do
              {:ok, public_runbook} -> [runbook_summary(runbook, public_runbook)]
              {:error, :incomplete_contract} -> []
            end
          end)
          |> Enum.filter(&summary_matches?(&1, query))
          |> Enum.sort_by(& &1.runbook_ref)

        {:ok, summaries}

      error ->
        error
    end
  end

  defp runbook_summary(runbook, public_runbook) do
    %{
      runbook_ref: runbook_ref(runbook),
      title: runbook.title,
      summary: summary(runbook.description),
      step_count: length(public_runbook.steps)
    }
  end

  defp summary(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.slice(0, 512)

  defp summary(_value), do: ""

  defp summary_matches?(_summary, nil), do: true

  defp summary_matches?(summary, query) do
    needle = String.downcase(query)

    Enum.any?([summary.runbook_ref, summary.title, summary.summary], fn value ->
      value |> String.downcase() |> String.contains?(needle)
    end)
  end

  # The controller already validated the published create_runbook_draft
  # inputSchema; the aggregate byte budget it documents as x-maxEncodedUtf8Bytes
  # is enforced here, where the whole-arguments encoding is at hand.
  defp validate_draft(args) do
    with :ok <- encoded_size(args, 57_344) do
      {:ok,
       %{
         title: args["title"],
         slug: args["slug"],
         description: args["description"] || "",
         steps: args["steps"]
       }}
    end
  end

  defp normalize_draft_steps(steps, snapshot) do
    steps
    |> Enum.reduce_while({:ok, [], MapSet.new(), 0}, fn step,
                                                        {:ok, normalized, seen, run_count} ->
      with {:ok, item, selected_count} <- normalize_draft_step(step, snapshot),
           false <- MapSet.member?(seen, item["id"]),
           next_count = run_count + selected_count,
           true <- next_count <= 256 do
        {:cont, {:ok, [item | normalized], MapSet.put(seen, item["id"]), next_count}}
      else
        _ ->
          {:halt,
           {:error,
            error("invalid_runbook", "Every step needs a unique valid exact action contract.")}}
      end
    end)
    |> case do
      {:ok, normalized, _seen, _run_count} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  # The published runbook_step schema owns field shapes; this keeps only what
  # it cannot express — the per-step args byte budget it documents as
  # x-maxRawUtf8Bytes, the trusted-contract match, and selector resolution.
  defp normalize_draft_step(step, snapshot) do
    with true <- byte_size(Jason.encode!(step["args"])) <= 32_768,
         %{} = pack <- Enum.find(snapshot.packs, &(&1.pack_ref == step["pack_ref"])),
         %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == step["action_id"])),
         :ok <- ActionContract.validate(step["args"], action),
         {:ok, selector, selected_count} <-
           normalize_selector(step["runner_selector"], snapshot, action) do
      {:ok,
       %{
         "id" => step["step_id"],
         "action_id" => step["action_id"],
         "pack_ref" => step["pack_ref"],
         "args" => step["args"],
         "runner_selector" => selector
       }, selected_count}
    else
      _ -> {:error, :invalid_step}
    end
  end

  defp normalize_selector(%{"runner_refs" => refs}, snapshot, action) do
    by_ref = Map.new(snapshot.runners, &{&1.runner_ref, &1})
    compatible = MapSet.new(action.compatible_runner_ids)
    selected = Enum.map(refs, &Map.get(by_ref, &1))

    if Enum.all?(selected, &(&1 && MapSet.member?(compatible, &1.id))) do
      {:ok, %{"runner_id" => Enum.map(selected, & &1.id), "runner_refs" => refs},
       length(selected)}
    else
      {:error, :invalid_selector}
    end
  end

  defp normalize_selector(%{"groups" => groups}, snapshot, action) do
    compatible = MapSet.new(action.compatible_runner_ids)
    visible_ids = MapSet.new(snapshot.runners, & &1.id)
    selected = Enum.filter(snapshot.account_runners, &(&1.group in groups))

    if length(selected) in 1..16 and
         Enum.all?(selected, fn runner ->
           MapSet.member?(visible_ids, runner.id) and MapSet.member?(compatible, runner.id)
         end) do
      {:ok, %{"group" => groups}, length(selected)}
    else
      {:error, :invalid_selector}
    end
  end

  defp draft_attrs(input, steps) do
    slug = draft_slug(input)

    %{
      "title" => input.title,
      "name" => input.title,
      "slug" => slug,
      "description" => input.description,
      "definition" => %{"steps" => steps}
    }
  end

  defp draft_facts(input) do
    %{
      "title" => input.title,
      "slug" => draft_slug(input),
      "description" => input.description,
      "steps" => input.steps
    }
  end

  defp draft_operation_attrs(input, operation_id, fingerprint, conn) do
    subject = conn.assigns.current_subject

    %{
      operation_id: operation_id,
      tool: :create_runbook_draft,
      fingerprint: fingerprint,
      resource_id: MCPOperations.resource_id(operation_id, :create_runbook_draft, subject),
      resource_ref: draft_slug(input)
    }
  end

  defp execution_operation_attrs(input, operation_id, fingerprint, conn) do
    subject = conn.assigns.current_subject

    %{
      operation_id: operation_id,
      tool: :execute_runbook,
      fingerprint: fingerprint,
      resource_id: MCPOperations.resource_id(operation_id, :execute_runbook, subject),
      resource_ref: input.runbook_ref
    }
  end

  defp draft_slug(input), do: input.slug || Slug.slugify(input.title, max_length: 79)

  defp draft_payload(runbook, operation_id, subject) do
    %{
      ok: true,
      operation_id: operation_id,
      draft_id: runbook.id,
      slug: runbook.slug,
      status: "draft",
      review_url:
        "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runbooks/#{runbook.id}/edit"
    }
  end

  defp preflight_runbook(conn, runbook) do
    with {:ok, snapshot} <- catalog_snapshot(conn),
         {:ok, public_runbook} <- RunbookContract.project(runbook, snapshot),
         {:ok, plan} <- Runbooks.resolve_plan(runbook, conn.assigns.current_subject),
         :ok <- validate_plan_contract(public_runbook, plan.plan, snapshot),
         false <- enforcing_plan?(plan.plan, snapshot.runners) do
      :ok
    else
      true -> {:error, :signed_runbook_unsupported}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :incomplete_contract} -> {:error, :incomplete_contract}
      _ -> {:error, :target_contract_changed}
    end
  end

  defp validate_plan_contract(public_runbook, plan, snapshot) do
    steps = Map.new(public_runbook.steps, &{&1.step_id, &1})
    packs = Map.new(snapshot.packs, &{&1.pack_ref, &1})

    if RunbookContract.valid_plan_size?(plan) and
         Enum.all?(plan, &valid_plan_item?(&1, steps, packs)),
       do: :ok,
       else: {:error, :target_contract_changed}
  end

  defp valid_plan_item?(item, steps, packs) do
    with %{} = step <- Map.get(steps, item.step_id),
         pack_ref when is_binary(pack_ref) <- step.pack_ref,
         %{} = pack <- Map.get(packs, pack_ref),
         %{} = action <- Enum.find(pack.actions, &(&1["action_id"] == item.action_id)) do
      item.runner_id in action.compatible_runner_ids
    else
      _ -> false
    end
  end

  defp enforcing_plan?(plan, runners) do
    enforcing_ids = runners |> Enum.filter(& &1.enforce_signatures) |> MapSet.new(& &1.id)
    Enum.any?(plan, &MapSet.member?(enforcing_ids, &1.runner_id))
  end

  defp execution_status(%{status: :halted}, _runs), do: "failed"
  defp execution_status(_execution, []), do: "pending"

  defp execution_status(execution, runs) do
    total = length(execution.work_list)

    cond do
      Enum.any?(runs, &(&1.status == :pending_approval)) ->
        "pending_approval"

      length(runs) < total ->
        "running"

      Enum.any?(runs, &(Runs.ActionRun.terminal?(&1.status) and &1.status != :success)) ->
        "failed"

      Enum.all?(runs, &(&1.status == :success)) ->
        "success"

      true ->
        "running"
    end
  end

  defp execution_steps(runbook, execution, runs) do
    steps = Runbooks.expand(runbook)
    runs_by_step = Enum.group_by(runs, & &1.runbook_step_id)

    execution.work_list
    |> Enum.group_by(& &1["step_index"])
    |> Enum.sort_by(fn {index, _items} -> index end)
    |> Enum.map(fn {index, items} ->
      step = Enum.at(steps, index)
      step_runs = Map.get(runs_by_step, step["id"], [])

      %{
        step_id: step["id"],
        action_id: step["action_id"],
        status: step_status(step_runs, length(items)),
        run_count: length(items),
        status_counts: step_status_counts(step_runs, length(items))
      }
    end)
  end

  defp step_status([], _planned), do: "pending"

  defp step_status(runs, planned) do
    cond do
      Enum.any?(runs, &(&1.status == :pending_approval)) ->
        "pending_approval"

      Enum.any?(runs, &(Runs.ActionRun.terminal?(&1.status) and &1.status != :success)) ->
        "failed"

      length(runs) == planned and Enum.all?(runs, &(&1.status == :success)) ->
        "success"

      true ->
        "running"
    end
  end

  defp step_status_counts(runs, planned) do
    counts =
      runs
      |> Enum.frequencies_by(&to_string(&1.status))
      |> Map.new()

    missing = planned - length(runs)
    if missing > 0, do: Map.update(counts, "pending", missing, &(&1 + missing)), else: counts
  end

  defp catalog_snapshot(conn) do
    subject = conn.assigns.current_subject

    with {:ok, runners} <- Runners.list_all_runners_for_account(subject),
         {:ok, actions} <- Catalog.list_all_actions_for_account(subject),
         {:ok, versions} <- Catalog.list_all_pack_versions_for_account(subject) do
      account_runners = runners
      ids = MapSet.new(runners, & &1.id)
      actions = Enum.filter(actions, &MapSet.member?(ids, &1.runner_id))

      snapshot =
        versions
        |> Catalog.MCPProjection.build(actions, runners)
        |> Map.put(:account_runners, account_runners)

      {:ok, snapshot}
    end
  end

  defp mutation_fingerprint(tool, facts) do
    ["emisar-mcp-mutation-v1", encode_fingerprint_value(tool), encode_fingerprint_value(facts)]
    |> IO.iodata_to_binary()
    |> Crypto.hash_hex()
  end

  defp encode_fingerprint_value(nil), do: "n"
  defp encode_fingerprint_value(true), do: "b1"
  defp encode_fingerprint_value(false), do: "b0"

  defp encode_fingerprint_value(value) when is_integer(value),
    do: ["i", Integer.to_string(value), ";"]

  defp encode_fingerprint_value(value) when is_float(value),
    do: ["f", :erlang.float_to_binary(value, [:short]), ";"]

  defp encode_fingerprint_value(value) when is_binary(value),
    do: ["s", Integer.to_string(byte_size(value)), ":", value]

  defp encode_fingerprint_value(value) when is_list(value) do
    ["l", Integer.to_string(length(value)), ":", Enum.map(value, &encode_fingerprint_value/1)]
  end

  defp encode_fingerprint_value(value) when is_map(value) do
    pairs = Enum.sort_by(value, fn {key, _value} -> key end)

    [
      "m",
      Integer.to_string(map_size(value)),
      ":",
      Enum.map(pairs, fn {key, item} ->
        [encode_fingerprint_value(key), encode_fingerprint_value(item)]
      end)
    ]
  end

  defp parse_runbook_ref(value) when is_binary(value) do
    case Regex.run(@runbook_ref, value) do
      [_, slug, version] -> {:ok, {slug, String.to_integer(version)}}
      _ -> {:error, :invalid_runbook_ref}
    end
  end

  defp parse_runbook_ref(_value), do: {:error, :invalid_runbook_ref}
  defp runbook_ref(runbook), do: "#{runbook.slug}@#{runbook.version}"

  defp encoded_size(args, max) do
    if byte_size(Jason.encode!(args)) <= max do
      :ok
    else
      {:error,
       ValidationError.payload("Arguments exceed the size limit.",
         stage: :arguments,
         issues: [ValidationError.issue([], :size)]
       )}
    end
  end

  defp split_more(items, limit) do
    if length(items) > limit, do: {Enum.take(items, limit), true}, else: {items, false}
  end

  defp fit_runbook_page(items, more?, observed_at, scope, filters) do
    next_cursor =
      if more? and items != [] do
        CatalogCursor.encode(
          "list_runbooks",
          scope,
          filters,
          List.last(items).runbook_ref
        )
      end

    payload = %{
      ok: true,
      observed_at: observed_at,
      runbooks: items,
      next_cursor: next_cursor
    }

    if items == [] or ResponseBudget.fits_payload?(payload) do
      payload
    else
      fit_runbook_page(Enum.drop(items, -1), true, observed_at, scope, filters)
    end
  end

  defp drop_through(items, nil), do: items
  defp drop_through(items, key), do: Enum.drop_while(items, &(&1.runbook_ref <= key))

  defp cursor_scope(conn) do
    Crypto.hash_hex(conn.assigns.current_subject.account.id <> "\0" <> conn.assigns.api_key.id)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp execution_error({:step_no_runners, step}), do: "Step #{step} has no executable runner."

  defp execution_error({:step_fan_out_too_large, max}),
    do: "One resolved runbook step exceeds #{max} runners."

  defp execution_error({:fan_out_too_large, max}), do: "The resolved runbook exceeds #{max} runs."
  defp execution_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp execution_error(_reason), do: "The runbook could not be started."

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error(code, message, dispatch_started \\ false, details \\ nil)

  defp error(code, message, dispatch_started, details) do
    error = %{code: code, message: message, retryable: false}
    error = if details, do: Map.put(error, :details, details), else: error
    %{ok: false, error: error, dispatch_started: dispatch_started}
  end
end

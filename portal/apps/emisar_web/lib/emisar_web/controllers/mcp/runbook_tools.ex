defmodule EmisarWeb.MCP.RunbookTools do
  @moduledoc """
  Fixed MCP runbook discovery, draft authoring, and execution boundary.

  MCP accepts and returns the same strict JSON-compatible definition used by
  persistence and the console. Runbooks owns compilation, authorization, and
  scheduling; this module only handles wire identity and bounded projection.
  """

  alias Emisar.{Approvals, Crypto, Runbooks}
  alias Emisar.Auth.Subject
  alias EmisarWeb.MCP.{CatalogCursor, ResponseBudget, RunbookContract, RunbookOutputCursor}
  alias EmisarWeb.MCP.Service
  alias EmisarWeb.MCP.ValidationError

  @default_limit 15
  @max_definition_issues 64
  @hidden_contract_reasons [
    :action_contract_changed,
    :action_not_found,
    :action_unavailable,
    :incomplete_contract,
    :not_found,
    :pack_ref_mismatch,
    :pack_retired,
    :pack_untrusted,
    :runner_not_found,
    :runner_out_of_scope,
    :target_contract_changed
  ]

  @doc "Executes one of the five fixed runbook tools."
  def call(conn, "list_runbooks", args, _operation_id), do: list_runbooks(conn, args)
  def call(conn, "get_runbook", args, _operation_id), do: get_runbook(conn, args)

  def call(conn, "execute_runbook", args, operation_id),
    do: execute_runbook(conn, args, operation_id)

  def call(conn, "create_runbook_draft", args, operation_id),
    do: create_draft(conn, args, operation_id)

  def call(conn, "update_runbook_draft", args, operation_id),
    do: update_draft(conn, args, operation_id)

  defp list_runbooks(conn, args) do
    query = args["query"]
    limit = args["limit"] || @default_limit

    with {:ok, summaries} <- runbook_summaries(conn, query),
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
        {:error, error("invalid_cursor", Service.invalid_cursor_message(:page, "list_runbooks"))}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read runbooks.")}
    end
  end

  defp get_runbook(conn, args) do
    slug = args["slug"]
    status = args["status"] || "published"

    with {:ok, runbook} <- fetch_runbook(conn, status, slug),
         {:ok, public_runbook} <- project_runbook(status, runbook) do
      {:ok, %{ok: true, runbook: public_runbook}}
    else
      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read runbooks.")}

      {:error, {:runbook_too_large, bytes}} ->
        {:error, runbook_too_large(bytes)}

      {:error, reason} when reason in [:not_found, :incomplete_contract] ->
        {:error, runbook_not_found(status)}
    end
  end

  defp fetch_runbook(conn, "published", slug),
    do: Runbooks.fetch_model_visible_runbook(slug, conn.assigns.current_subject)

  defp fetch_runbook(conn, "draft", slug),
    do: Runbooks.fetch_model_runbook_draft(slug, conn.assigns.current_subject)

  defp project_runbook("published", runbook), do: RunbookContract.project(runbook)
  defp project_runbook("draft", runbook), do: RunbookContract.project_draft(runbook)

  defp runbook_not_found("published"),
    do: error("runbook_not_found", "No live runbook has that slug.")

  defp runbook_not_found("draft"),
    do: error("draft_not_found", "That runbook has no unpublished changes.")

  # Size is a mechanical limit, not a resolution failure, so it is named rather
  # than folded into "no such runbook" — the runbook exists, it is in the
  # console, and answering that it does not is simply false.
  defp runbook_too_large(bytes) do
    error(
      "runbook_too_large",
      "This runbook projects to #{bytes} bytes, over the #{RunbookContract.max_projection_bytes()} byte limit for one MCP response. Open it in the console to read or run it."
    )
  end

  defp create_draft(conn, args, operation_id) do
    facts = draft_facts(args, operation_id)

    case create_or_replay_draft(conn, facts) do
      {:ok, _kind, runbook} ->
        draft_result(conn, runbook, operation_id)

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

      {:error, issues} when is_list(issues) ->
        {:error, definition_issue_error(issues)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         error("invalid_draft", "The draft failed validation.", false, %{
           fields: changeset_errors(changeset)
         })}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot create runbook drafts.")}

      {:error, %{} = payload} ->
        {:error, payload}
    end
  end

  defp create_or_replay_draft(conn, facts) do
    with :ok <- validate_draft_envelope(facts) do
      Runbooks.create_or_replay_mcp_draft(facts, conn.assigns.current_subject)
    end
  end

  defp update_draft(conn, args, operation_id) do
    facts = draft_update_facts(args, operation_id)

    case update_or_replay_draft(conn, facts) do
      {:ok, _kind, runbook} ->
        draft_result(conn, runbook, operation_id)

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

      # A runbook that does not exist is NOT a stale read. Folding :not_found in
      # here answered "the draft changed, fetch it again" for a slug that has
      # nothing to fetch — the wrong remedy, and it contradicted get_runbook,
      # which answers runbook_not_found for the same slug. A model given two
      # different answers about one object retries the useless one.
      {:error, :not_found} ->
        {:error, error("runbook_not_found", "No runbook has that slug.")}

      {:error, :draft_changed} ->
        {:error,
         error(
           "draft_changed",
           "The draft changed since you read it. Fetch it again (get_runbook status=draft) before editing."
         )}

      {:error, issues} when is_list(issues) ->
        {:error, definition_issue_error(issues)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error,
         error("invalid_draft", "The draft failed validation.", false, %{
           fields: changeset_errors(changeset)
         })}

      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot update runbook drafts.")}
    end
  end

  defp update_or_replay_draft(conn, facts) do
    with :ok <- validate_draft_envelope(facts) do
      Runbooks.create_or_replay_mcp_draft_update(facts, conn.assigns.current_subject)
    end
  end

  defp execute_runbook(conn, args, operation_id) do
    allow_draft? = args["allow_draft"] || false
    facts = execution_facts(args, operation_id, allow_draft?)
    # A draft run names its runbook by slug alone, so the rejection log records
    # whichever identity the call actually carried.
    runbook_ref = args["runbook_ref"] || args["slug"]

    with {:ok, _outcome, execution} <-
           Runbooks.create_or_replay_mcp_execution(facts, conn.assigns.current_subject),
         {:ok, payload} <- execution_payload(conn, execution.id) do
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

      {:error, :unauthorized} ->
        not_allowed(conn, runbook_ref)

      {:error, reason} when reason in [:draft_not_found, :draft_changed] ->
        draft_changed(conn, runbook_ref)

      {:error, reason} ->
        execution_rejected(conn, runbook_ref, reason, allow_draft?)
    end
  end

  # A draft has no release number to name, so the exact-content consent a draft
  # run carries is its slug plus the digest of what the caller read.
  defp execution_facts(args, operation_id, true) do
    %{
      operation_id: operation_id,
      slug: args["slug"],
      definition_sha256: args["definition_sha256"],
      allow_draft: true,
      reason: args["reason"],
      input_values: args["input_values"] || %{}
    }
  end

  defp execution_facts(args, operation_id, false) do
    %{
      operation_id: operation_id,
      runbook_ref: args["runbook_ref"],
      allow_draft: false,
      reason: args["reason"],
      input_values: args["input_values"] || %{}
    }
  end

  defp draft_changed(conn, runbook_ref) do
    :ok =
      ValidationError.log_dispatch_rejected(conn, "execute_runbook", "draft_changed",
        runbook_ref: runbook_ref
      )

    {:error,
     error(
       "draft_changed",
       "This runbook has no unpublished change with that exact content. Read it again (get_runbook status=draft) before executing it."
     )}
  end

  defp not_allowed(conn, runbook_ref) do
    :ok =
      ValidationError.log_dispatch_rejected(conn, "execute_runbook", "not_allowed",
        runbook_ref: runbook_ref
      )

    {:error, error("not_allowed", "This key cannot execute this runbook.")}
  end

  defp execution_rejected(
         conn,
         runbook_ref,
         [%{code: _code, path: _path} | _rest] = reason,
         allow_draft
       ) do
    :ok = log_target_contract_changed(conn, runbook_ref)
    {:error, execution_failure(reason, allow_draft)}
  end

  defp execution_rejected(conn, runbook_ref, reason, allow_draft)
       when reason in @hidden_contract_reasons do
    :ok = log_target_contract_changed(conn, runbook_ref)
    {:error, execution_failure(reason, allow_draft)}
  end

  defp execution_rejected(_conn, _runbook_ref, reason, allow_draft),
    do: {:error, execution_failure(reason, allow_draft)}

  defp log_target_contract_changed(conn, runbook_ref) do
    ValidationError.log_dispatch_rejected(conn, "execute_runbook", "target_contract_changed",
      runbook_ref: runbook_ref
    )
  end

  @doc false
  def execution_failure(reason), do: execution_failure(reason, false)

  defp execution_failure(reason, false) when reason in @hidden_contract_reasons do
    error("runbook_not_found", "No live runbook has that exact ref.")
  end

  defp execution_failure(reason, true) when reason in @hidden_contract_reasons do
    error("draft_not_found", "That runbook has no unpublished changes.")
  end

  defp execution_failure(:not_live, _allow_draft) do
    error(
      "not_live",
      "That release is not the live version of this runbook. list_runbooks shows what is."
    )
  end

  defp execution_failure(:runner_requires_attestation, _allow_draft) do
    error(
      "signed_runbook_unsupported",
      "A runbook cannot execute on a signed-only runner because the bridge signs only direct run_action calls."
    )
  end

  defp execution_failure(:runbook_capacity_exceeded, _allow_draft) do
    "runbook_capacity_exceeded"
    |> error(
      "This account already has 1,024 active runbook items. Wait for an execution to finish or cancel one, then try again."
    )
    |> put_in([:error, :retryable], true)
  end

  defp execution_failure(
         [%{code: _code, message: _message, path: _path} | _rest] = issues,
         _allow_draft
       ),
       do: issue_error(issues)

  defp execution_failure(_reason, _allow_draft) do
    error("execution_failed", "The runbook could not be started.")
  end

  @doc "Builds the fixed execution projection used by execute, wait, and recovery."
  def execution_payload(conn, execution_id) when is_binary(execution_id) do
    subject = conn.assigns.current_subject

    with {:ok, result} <- Runbooks.fetch_execution_result(execution_id, subject) do
      projection = Runbooks.execution_projection(result)

      project_execution(result, projection, subject, output_scope: Service.cursor_scope(conn))
    end
  end

  @doc false
  def project_execution(%{execution: execution, runbook: runbook} = result, %Subject{} = subject) do
    projection = Runbooks.execution_projection(result)

    project_execution(execution, runbook, projection, subject, [])
  end

  @doc false
  def project_execution(
        %{execution: execution, runbook: runbook},
        projection,
        %Subject{} = subject
      ) do
    project_execution(execution, runbook, projection, subject, [])
  end

  @doc false
  def project_execution(
        %{execution: execution, runbook: runbook},
        projection,
        %Subject{} = subject,
        opts
      )
      when is_list(opts) do
    project_execution(execution, runbook, projection, subject, opts)
  end

  defp project_execution(execution, runbook, projection, subject, opts) do
    approval = execution_approval(execution, subject)
    output_scope = Keyword.get(opts, :output_scope)

    [:full, :summary, :minimal]
    |> Enum.reduce_while({:error, :response_too_large}, fn mode, _result ->
      payload =
        execution_projection(execution, runbook, projection, approval, mode, output_scope)

      if ResponseBudget.fits_payload?(%{ok: true, execution: payload}) do
        {:halt, {:ok, payload}}
      else
        {:cont, {:error, :response_too_large}}
      end
    end)
  end

  defp execution_approval(%{status: :pending_approval} = execution, subject) do
    case Approvals.fetch_request_for_visible_runbook_execution(execution, subject) do
      {:ok, request} -> Service.approval_summary(request, subject)
      _ -> nil
    end
  end

  defp execution_approval(_execution, _subject), do: nil

  defp execution_projection(execution, runbook, projection, approval, mode, output_scope) do
    %{
      runbook_execution_id: execution.id,
      runbook_ref: execution_runbook_ref(execution, runbook),
      kind: to_string(execution.kind),
      definition_sha256: execution.definition_sha256,
      status: to_string(projection.execution.status),
      blocking: blocking(projection.execution.blocking),
      stages: Enum.map(projection.stages, &stage_projection(&1, mode)),
      runs_next: %{
        tool: "recent_runs",
        arguments: %{runbook_execution_id: execution.id, limit: 15}
      }
    }
    |> maybe_put(:approval, approval)
    |> maybe_put(:wait_until, approval[:expires_at])
    |> maybe_put(:next, wait_next(execution.id, projection.execution.waitable?))
    |> maybe_put(:outputs_next, outputs_next(execution.id, projection, mode, output_scope))
  end

  defp wait_next(_execution_id, false), do: nil

  defp wait_next(execution_id, true),
    do: %{tool: "wait_for_run", arguments: %{runbook_execution_id: execution_id, timeout: "60s"}}

  defp outputs_next(_execution_id, _projection, :full, _scope), do: nil
  defp outputs_next(_execution_id, _projection, _mode, nil), do: nil

  defp outputs_next(execution_id, projection, _mode, scope) do
    if projection.execution.terminal? and public_output_value?(projection) do
      output_next(execution_id, scope, 0)
    end
  end

  defp public_output_value?(projection) do
    Enum.any?(projection.stages, fn stage ->
      Enum.any?(stage.items, fn item ->
        Enum.any?(item.outputs, &(not &1.sensitive and not is_nil(&1.value)))
      end)
    end)
  end

  defp output_next(execution_id, scope, position) do
    %{
      tool: "wait_for_run",
      arguments: %{
        runbook_execution_id: execution_id,
        cursor: RunbookOutputCursor.encode(scope, execution_id, position),
        timeout: "0"
      }
    }
  end

  @doc false
  def project_execution_output_page(result, position, scope)
      when is_integer(position) and position >= 0 and is_binary(scope) do
    projection = Runbooks.execution_projection(result)
    outputs = execution_outputs(projection)

    if projection.execution.terminal? and position < length(outputs) do
      fit_output_page(result.execution.id, outputs, position, scope)
    else
      {:error, :invalid_cursor}
    end
  end

  defp execution_outputs(projection) do
    Enum.flat_map(projection.stages, fn stage ->
      Enum.flat_map(stage.items, fn item ->
        Enum.map(item.outputs, fn output ->
          %{
            item_id: item.id,
            stage_id: stage.stage_id,
            step_id: item.step_id,
            runner_ref: item.runner_ref,
            output_id: output.output_id,
            source: output.source,
            sensitive: output.sensitive,
            status: output.status,
            value: output.value
          }
        end)
      end)
    end)
  end

  defp fit_output_page(execution_id, outputs, position, scope) do
    remaining = length(outputs) - position
    upper = min(remaining, 100)
    build = &output_page(execution_id, outputs, position, &1, scope)
    count = largest_fitting_output_count(build, 1, upper, 0)

    if count > 0,
      do: {:ok, build.(count)},
      else: {:error, :response_too_large}
  end

  defp largest_fitting_output_count(build, low, high, best) when low <= high do
    count = div(low + high, 2)

    if ResponseBudget.fits_model_page?(%{ok: true, execution_outputs: build.(count)}) do
      largest_fitting_output_count(build, count + 1, high, count)
    else
      largest_fitting_output_count(build, low, count - 1, best)
    end
  end

  defp largest_fitting_output_count(_build, _low, _high, best), do: best

  defp output_page(execution_id, outputs, position, count, scope) do
    total_count = length(outputs)
    next_position = position + count

    %{
      runbook_execution_id: execution_id,
      total_count: total_count,
      returned_count: count,
      remaining_count: total_count - next_position,
      outputs: outputs |> Enum.drop(position) |> Enum.take(count)
    }
    |> maybe_put(
      :next,
      if(next_position < total_count, do: output_next(execution_id, scope, next_position))
    )
  end

  # A draft test ran content that never became a release, so it has no number to
  # name — the slug plus the execution's own digest is its identity.
  defp execution_runbook_ref(%{runbook_version: nil}, runbook), do: runbook.slug

  defp execution_runbook_ref(execution, runbook),
    do: "#{runbook.slug}@#{execution.runbook_version}"

  defp blocking(nil), do: nil

  defp blocking(cause) do
    %{code: cause.code, message: cause.message}
    |> maybe_put(:stage_id, cause.stage_id)
    |> maybe_put(:step_id, cause.step_id)
    |> maybe_put(:runner_ref, cause.runner_ref)
  end

  defp stage_projection(stage, mode) do
    %{
      stage_id: stage.stage_id,
      title: stage.title,
      position: stage.position,
      mode: to_string(stage.mode),
      max_parallel: stage.max_parallel,
      status: to_string(stage.status),
      items: Enum.map(stage.items, &item_projection(&1, mode))
    }
  end

  defp item_projection(item, mode) do
    %{
      item_id: item.id,
      step_id: item.step_id,
      runner_ref: item.runner_ref,
      target_selection: item.target_selection,
      target_group: item.target_group,
      status: wire_status(item.status),
      action_id: item.action_id,
      pack_ref: item.pack_ref,
      pack_hash: item.pack_hash,
      risk: item.risk,
      attempt_count: item.attempt_count,
      wait: wait_projection(item),
      outputs: output_results(item.outputs, mode),
      output_count: item.output_count,
      output_values_omitted: mode != :full,
      conditions: condition_results(item.conditions, mode),
      condition_count: item.condition_count,
      error: item_error(item),
      latest_attempt: attempt_projection(item.latest_attempt)
    }
  end

  # The domain names an item's effective status for operators; the published
  # enum is frozen, so an inherited or never-dispatched status reports as the
  # persisted state it stands for.
  defp wire_status(:queued), do: "pending"
  defp wire_status(:halted), do: "pending"
  defp wire_status(:not_run), do: "failed"
  defp wire_status(status), do: to_string(status)

  defp output_results(_outputs, :minimal), do: []

  defp output_results(outputs, mode) do
    Enum.map(outputs, fn output ->
      %{
        output_id: output.output_id,
        source: output.source,
        sensitive: output.sensitive,
        status: output.status,
        value: output_value(output, mode)
      }
    end)
  end

  # Every value the domain could not prove public already reads `[REDACTED]`,
  # so a downgrade only ever hashes or sizes a value this caller may read.
  defp output_value(output, :full), do: output.value
  defp output_value(%{sensitive: true} = output, :summary), do: output.value
  defp output_value(%{value: nil}, :summary), do: nil

  defp output_value(output, :summary) do
    encoded = Jason.encode!(output.value)

    %{
      omitted: true,
      encoded_bytes: byte_size(encoded),
      sha256: Crypto.hash_hex(encoded)
    }
  end

  defp condition_results(_conditions, :minimal), do: []

  defp condition_results(conditions, mode) do
    Enum.map(conditions, fn condition ->
      %{
        output: condition.output,
        operator: condition.operator,
        expected: expected_value(condition, mode),
        status: condition.status
      }
    end)
  end

  defp expected_value(condition, :full), do: condition.expected
  defp expected_value(%{sensitive: true} = condition, :summary), do: condition.expected
  defp expected_value(_condition, :summary), do: nil

  defp wait_projection(%{wait: nil}), do: nil

  defp wait_projection(item) do
    %{
      interval_seconds: item.wait["interval_seconds"],
      timeout_seconds: item.wait["timeout_seconds"],
      max_attempts: item.wait["max_attempts"],
      started_at: item.wait_started_at,
      next_attempt_at: item.next_attempt_at
    }
  end

  defp item_error(%{terminal_code: nil}), do: nil

  defp item_error(item),
    do: %{code: item.terminal_code, message: item.terminal_message || "Item halted."}

  defp attempt_projection(nil), do: nil

  defp attempt_projection(attempt) do
    %{
      run_id: attempt.id,
      attempt_number: attempt.attempt_number,
      status: to_string(attempt.status),
      duration_ms: attempt.duration_ms,
      started_at: attempt.started_at,
      finished_at: attempt.finished_at
    }
  end

  # One entry per runbook, whether it is live, carries an unpublished change, or
  # both. Live discovery hides a runbook whose targets no longer resolve; draft
  # discovery does not, because a broken change must stay repairable.
  defp runbook_summaries(conn, query) do
    subject = conn.assigns.current_subject

    with {:ok, live} <- Runbooks.list_model_visible_runbooks(subject),
         {:ok, drafts} <- Runbooks.list_model_draft_runbooks(subject) do
      {:ok, summaries(live ++ drafts, query)}
    end
  end

  defp summaries(runbooks, query) do
    runbooks
    |> Enum.uniq_by(& &1.id)
    |> Enum.flat_map(&projected_summary/1)
    |> Enum.filter(&summary_matches?(&1, query))
    |> Enum.sort_by(& &1.slug)
  end

  # A runbook too large to project stays LISTED and says so. Only the
  # resolution failures — an unresolvable pack, runner, or action — are hidden,
  # because those would leak the existence of infrastructure out of scope.
  defp projected_summary(runbook) do
    case RunbookContract.summarize(runbook) do
      {:ok, summary} -> [summary]
      {:error, :incomplete_contract} -> []
    end
  end

  defp summary_matches?(_summary, nil), do: true

  defp summary_matches?(summary, query) do
    needle = String.downcase(query)

    Enum.any?([summary.slug, summary.title, summary.summary], fn value ->
      value |> String.downcase() |> String.contains?(needle)
    end)
  end

  defp draft_facts(args, operation_id) do
    %{
      operation_id: operation_id,
      title: args["title"],
      slug: Runbooks.resolve_slug(args["title"], args["slug"]),
      description: args["description"],
      definition: args["definition"]
    }
  end

  defp draft_update_facts(args, operation_id) do
    %{
      operation_id: operation_id,
      slug: args["slug"],
      definition_sha256: args["definition_sha256"],
      title: args["title"],
      description: args["description"],
      definition: args["definition"]
    }
  end

  # The envelope must fit in the transport's bounded frame before the domain
  # spends a transaction on it; the definition contract itself is Runbooks'.
  defp validate_draft_envelope(facts) do
    facts
    |> Map.take([:title, :slug, :description, :definition])
    |> encoded_size(Runbooks.definition_limit!(:max_definition_bytes) + 8_192)
  end

  # The write succeeded, so what the model still needs is the pair: the draft it
  # just authored does not run, and this names the release that does.
  defp draft_result(conn, runbook, operation_id),
    do: {:ok, draft_payload(runbook, operation_id, conn.assigns.current_subject)}

  defp draft_payload(runbook, operation_id, subject) do
    %{
      ok: true,
      operation_id: operation_id,
      draft_id: runbook.id,
      slug: runbook.slug,
      status: "draft",
      definition_sha256: Runbooks.definition_digest(runbook.draft_definition),
      live_ref: RunbookContract.live_ref(runbook),
      review_url:
        "#{EmisarWeb.Endpoint.url()}/app/#{subject.account.slug}/runbooks/#{runbook.id}/edit"
    }
  end

  defp encoded_size(args, max) do
    if byte_size(Jason.encode!(args)) <= max do
      :ok
    else
      {:error,
       [
         %{
           code: "invalid_definition",
           path: "",
           message: "Draft exceeds the encoded byte limit."
         }
       ]}
    end
  rescue
    Jason.EncodeError ->
      {:error,
       [
         %{
           code: "invalid_definition",
           path: "",
           message: "Draft must contain only JSON values."
         }
       ]}
  end

  defp split_more(items, limit) do
    if length(items) > limit, do: {Enum.take(items, limit), true}, else: {items, false}
  end

  defp fit_runbook_page(items, more?, observed_at, scope, filters) do
    next_cursor =
      if more? and items != [] do
        CatalogCursor.encode("list_runbooks", scope, filters, List.last(items).slug)
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
  defp drop_through(items, key), do: Enum.drop_while(items, &(&1.slug <= key))

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

  defp issue_error([first | _rest] = issues) do
    details = %{issues: Enum.take(issues, 8)}

    first.code
    |> error(first.message, false, details)
    |> update_in([:error], &Map.put(&1, :path, first.path))
  end

  defp definition_issue_error(issues) do
    issue_count = length(issues)
    visible_issues = Enum.take(issues, @max_definition_issues)
    noun = if issue_count == 1, do: "issue", else: "issues"

    error(
      "invalid_runbook",
      "The draft has #{issue_count} definition #{noun}.",
      false,
      %{
        issue_count: issue_count,
        issues_truncated: issue_count > length(visible_issues),
        issues: visible_issues
      }
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error(code, message, dispatch_started \\ false, details \\ nil)

  defp error(code, message, dispatch_started, details) do
    error = %{code: code, message: message, retryable: false}
    error = if details, do: Map.put(error, :details, details), else: error
    %{ok: false, error: error, dispatch_started: dispatch_started}
  end
end

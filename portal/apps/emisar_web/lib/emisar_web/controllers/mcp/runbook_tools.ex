defmodule EmisarWeb.MCP.RunbookTools do
  @moduledoc """
  Fixed MCP runbook discovery, draft creation, and execution boundary.

  MCP accepts and returns the same strict JSON-compatible definition used by
  persistence and the console. Runbooks owns compilation, authorization, and
  scheduling; this module only handles wire identity and bounded projection.
  """

  alias Emisar.{Approvals, Crypto, Runbooks, Slug}
  alias Emisar.Auth.Subject
  alias EmisarWeb.MCP.{CatalogCursor, ResponseBudget, RunbookContract, Service}
  alias EmisarWeb.MCP.ValidationError

  @runbook_ref ~r/\A([a-z][a-z0-9_-]{0,79})@([1-9][0-9]*)\z/
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

    with {:ok, summaries} <- published_summaries(conn, query),
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
    {:ok, {slug, version}} = parse_runbook_ref(args["runbook_ref"])

    with {:ok, runbook} <-
           Runbooks.fetch_published_runbook_version(slug, version, conn.assigns.current_subject),
         :ok <-
           Runbooks.validate_model_visible_runbook(runbook, conn.assigns.current_subject),
         {:ok, public_runbook} <- RunbookContract.project(runbook) do
      {:ok, %{ok: true, runbook: public_runbook}}
    else
      {:error, :unauthorized} ->
        {:error, error("not_allowed", "This key cannot read runbooks.")}

      {:error, reason} when reason in [:not_found, :incomplete_contract] ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}

      {:error, issues} when is_list(issues) ->
        {:error, error("runbook_not_found", "No published runbook has that exact ref.")}
    end
  end

  defp create_draft(conn, args, operation_id) do
    facts = draft_facts(args, operation_id)

    case create_or_replay_draft(conn, facts) do
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

  defp execute_runbook(conn, args, operation_id) do
    facts = %{
      operation_id: operation_id,
      runbook_ref: args["runbook_ref"],
      reason: args["reason"],
      input_values: args["input_values"] || %{}
    }

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
        not_allowed(conn, facts.runbook_ref)

      {:error, reason} ->
        execution_rejected(conn, facts.runbook_ref, reason)
    end
  end

  defp not_allowed(conn, runbook_ref) do
    :ok =
      ValidationError.log_dispatch_rejected(conn, "execute_runbook", "not_allowed",
        runbook_ref: runbook_ref
      )

    {:error, error("not_allowed", "This key cannot execute this runbook.")}
  end

  defp execution_rejected(conn, runbook_ref, [%{code: _code, path: _path} | _rest] = reason) do
    :ok = log_target_contract_changed(conn, runbook_ref)
    {:error, execution_failure(reason)}
  end

  defp execution_rejected(conn, runbook_ref, reason) when reason in @hidden_contract_reasons do
    :ok = log_target_contract_changed(conn, runbook_ref)
    {:error, execution_failure(reason)}
  end

  defp execution_rejected(_conn, _runbook_ref, reason), do: {:error, execution_failure(reason)}

  defp log_target_contract_changed(conn, runbook_ref) do
    ValidationError.log_dispatch_rejected(conn, "execute_runbook", "target_contract_changed",
      runbook_ref: runbook_ref
    )
  end

  @doc false
  def execution_failure(reason) when reason in @hidden_contract_reasons do
    error("runbook_not_found", "No published runbook has that exact ref.")
  end

  def execution_failure(:runner_requires_attestation) do
    error(
      "signed_runbook_unsupported",
      "A runbook cannot execute on a signed-only runner because the bridge signs only direct run_action calls."
    )
  end

  def execution_failure(:runbook_capacity_exceeded) do
    "runbook_capacity_exceeded"
    |> error(
      "This account already has 1,024 active runbook items. Wait for an execution to finish or cancel one, then try again."
    )
    |> put_in([:error, :retryable], true)
  end

  def execution_failure([%{code: _code, message: _message, path: _path} | _rest] = issues),
    do: issue_error(issues)

  def execution_failure(_reason) do
    error("execution_failed", "The runbook could not be started.")
  end

  @doc "Builds the fixed execution projection used by execute, wait, and recovery."
  def execution_payload(conn, execution_id) when is_binary(execution_id) do
    subject = conn.assigns.current_subject

    with {:ok, result} <- Runbooks.fetch_execution_result(execution_id, subject) do
      project_execution(result, subject)
    end
  end

  @doc false
  def project_execution(
        %{
          execution: execution,
          runbook: runbook,
          latest_attempts: latest_attempts
        },
        %Subject{} = subject
      ) do
    attempts_by_item = Map.new(latest_attempts, &{&1.runbook_execution_item_id, &1})
    approval = execution_approval(execution, subject)

    [:full, :summary, :minimal]
    |> Enum.reduce_while({:error, :response_too_large}, fn mode, _result ->
      payload = execution_projection(execution, runbook, attempts_by_item, approval, mode)

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

  defp execution_projection(execution, runbook, attempts_by_item, approval, mode) do
    items_by_stage = Enum.group_by(execution.items, & &1.runbook_execution_stage_id)

    %{
      runbook_execution_id: execution.id,
      runbook_ref: runbook_ref(runbook),
      status: to_string(execution.status),
      blocking: blocking(execution),
      stages:
        Enum.map(execution.stages, fn stage ->
          stage_items = Map.get(items_by_stage, stage.id, [])
          stage_projection(stage, stage_items, attempts_by_item, mode)
        end),
      runs_next: %{
        tool: "recent_runs",
        arguments: %{runbook_execution_id: execution.id, limit: 15}
      }
    }
    |> maybe_put(:approval, approval)
    |> maybe_put(:wait_until, approval[:expires_at])
    |> maybe_put(
      :next,
      if(execution.status in [:active, :pending_approval],
        do: %{
          tool: "wait_for_run",
          arguments: %{runbook_execution_id: execution.id, timeout: "60s"}
        }
      )
    )
  end

  defp stage_projection(stage, items, attempts_by_item, mode) do
    %{
      stage_id: stage.stage_id,
      title: stage.title,
      position: stage.position,
      mode: to_string(stage.mode),
      max_parallel: stage.max_parallel,
      status: to_string(stage.status),
      items:
        Enum.map(items, fn item ->
          item_projection(item, Map.get(attempts_by_item, item.id), mode)
        end)
    }
  end

  defp item_projection(item, attempt, mode) do
    %{
      item_id: item.id,
      step_id: item.step_id,
      runner_ref: item.runner_ref,
      target_selection: item.target_selection,
      target_group: item.target_group,
      status: to_string(item.status),
      action_id: item.action_id,
      pack_ref: item.pack_ref,
      pack_hash: item.pack_hash,
      risk: item.risk,
      attempt_count: item.attempt_count,
      wait: wait_projection(item),
      outputs: output_results(item, mode),
      output_count: length(item.output_plan),
      output_values_omitted: mode != :full,
      conditions: condition_results(item, mode),
      condition_count: length(item.success_plan),
      error: item_error(item),
      latest_attempt: attempt_projection(attempt)
    }
  end

  defp output_results(_item, :minimal), do: []

  defp output_results(item, mode) do
    evidence =
      item.success_evidence
      |> Enum.filter(&(&1["kind"] == "extraction"))
      |> Map.new(&{&1["output"], &1})

    Enum.map(item.output_plan, fn declaration ->
      id = declaration["id"]
      row = Map.get(evidence, id, %{})
      value = Map.get(item.outputs, id)

      %{
        output_id: id,
        source: declaration["source"],
        sensitive: declaration["sensitive"],
        status: row["status"] || "pending",
        value: output_value(value, declaration["sensitive"], mode)
      }
    end)
  end

  defp output_value(value, _sensitive, :full), do: value
  defp output_value("[REDACTED]", true, :summary), do: "[REDACTED]"
  defp output_value(nil, _sensitive, :summary), do: nil

  defp output_value(value, _sensitive, :summary) do
    encoded = Jason.encode!(value)

    %{
      omitted: true,
      encoded_bytes: byte_size(encoded),
      sha256: Crypto.hash_hex(encoded)
    }
  end

  defp condition_results(_item, :minimal), do: []

  defp condition_results(item, mode) do
    evidence = Enum.filter(item.success_evidence, &(&1["kind"] == "condition"))

    item.success_plan
    |> Enum.with_index()
    |> Enum.map(fn {condition, index} ->
      row = Enum.at(evidence, index, %{})
      sensitive? = output_sensitive?(item.output_plan, condition["output"])

      %{
        output: condition["output"],
        operator: condition["operator"],
        expected: expected_value(condition["value"], sensitive?, mode),
        status: row["status"] || "pending"
      }
    end)
  end

  defp expected_value(_value, true, _mode), do: "[REDACTED]"
  defp expected_value(value, false, :full), do: value
  defp expected_value(_value, false, :summary), do: nil

  defp output_sensitive?(output_plan, output_id) do
    Enum.any?(output_plan, &(&1["id"] == output_id and &1["sensitive"]))
  end

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

  defp blocking(%{terminal_code: code} = execution) when is_binary(code) do
    stage = Enum.find(execution.stages, &(&1.status in [:halted, :cancelled]))

    execution.items
    |> Enum.find(&(&1.status in [:failed, :cancelled]))
    |> blocking_from_terminal(execution, stage)
  end

  defp blocking(%{status: :pending_approval}),
    do: %{code: "approval_required", message: "Runbook execution approval is required."}

  defp blocking(execution), do: waiting_block(execution)

  defp blocking_from_terminal(nil, execution, stage) do
    %{
      code: execution.terminal_code,
      message: execution.terminal_message || "Execution halted."
    }
    |> maybe_put(:stage_id, stage && stage.stage_id)
  end

  defp blocking_from_terminal(item, _execution, stage) do
    %{
      code: item.terminal_code || "action_failed",
      message: item.terminal_message || "A runbook item did not succeed.",
      step_id: item.step_id,
      runner_ref: item.runner_ref
    }
    |> maybe_put(:stage_id, stage && stage.stage_id)
  end

  defp waiting_block(execution) do
    case Enum.find(execution.items, &(&1.status == :waiting)) do
      nil ->
        nil

      item ->
        stage =
          Enum.find(
            execution.stages,
            &(&1.id == item.runbook_execution_stage_id)
          )

        %{
          code: "waiting",
          message: "A success condition is waiting for another observation.",
          step_id: item.step_id,
          runner_ref: item.runner_ref
        }
        |> maybe_put(:stage_id, stage && stage.stage_id)
    end
  end

  defp published_summaries(conn, query) do
    case Runbooks.list_all_runbooks(conn.assigns.current_subject) do
      {:ok, runbooks} ->
        summaries =
          runbooks
          |> Enum.filter(&(&1.status == :published))
          |> Enum.group_by(& &1.slug)
          |> Enum.map(fn {_slug, versions} -> Enum.max_by(versions, & &1.version) end)
          |> Enum.flat_map(fn runbook ->
            with :ok <-
                   Runbooks.validate_model_visible_runbook(
                     runbook,
                     conn.assigns.current_subject
                   ),
                 {:ok, public_runbook} <- RunbookContract.project(runbook) do
              [runbook_summary(runbook, public_runbook)]
            else
              _hidden_or_invalid -> []
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
      summary: text_summary(runbook.description),
      input_count: public_runbook.summary.input_count,
      stage_count: public_runbook.summary.stage_count,
      step_count: public_runbook.summary.step_count
    }
  end

  defp text_summary(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/, " ") |> String.slice(0, 512)

  defp text_summary(_value), do: ""

  defp summary_matches?(_summary, nil), do: true

  defp summary_matches?(summary, query) do
    needle = String.downcase(query)

    Enum.any?([summary.runbook_ref, summary.title, summary.summary], fn value ->
      value |> String.downcase() |> String.contains?(needle)
    end)
  end

  defp draft_facts(args, operation_id) do
    %{
      operation_id: operation_id,
      title: args["title"],
      slug: normalized_slug(args["slug"], args["title"]),
      description: args["description"],
      definition: args["definition"]
    }
  end

  # The envelope must fit in the transport's bounded frame before the domain
  # spends a transaction on it; the definition contract itself is Runbooks'.
  defp validate_draft_envelope(facts) do
    envelope = %{
      "title" => facts.title,
      "slug" => facts.slug,
      "description" => facts.description,
      "definition" => facts.definition
    }

    encoded_size(envelope, Runbooks.Definition.limit!(:max_definition_bytes) + 8_192)
  end

  defp normalized_slug(nil, title), do: Slug.slugify(title, max_length: 79)

  defp normalized_slug(slug, title) when is_binary(slug) do
    if String.trim(slug) == "", do: Slug.slugify(title, max_length: 79), else: slug
  end

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

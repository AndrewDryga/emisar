defmodule Emisar.Runbooks do
  @moduledoc """
  Runbook authoring and execution.

  Definitions are validated as one bounded, JSON-compatible contract. At
  dispatch, the compiler freezes exact runners, trusted packs, and action
  contracts into durable stage and item rows. The scheduler then advances
  stages in order, applies sequential or bounded-parallel step semantics,
  evaluates extracted output, and stops on every refusal or failure.
  """
  use Supervisor
  alias Ecto.Multi
  alias Emisar.{Accounts, Approvals, Audit, Auth, Crypto, MCPOperations, Repo, Runs}
  alias Emisar.Auth.Subject
  alias Emisar.Runbooks.{Authorizer, Compiler, Definition, Runbook, RunbookExecution, Scheduler}
  alias Emisar.Runbooks.ExecutionItem

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("AdvanceExecutions")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Reads -----------------------------------------------------------

  def list_runbooks(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.ordered_by_title_version()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runbook.Query, opts)
    end
  end

  @doc "Lists every runbook visible to the subject for bounded in-memory MCP projection."
  def list_all_runbooks(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      runbooks =
        Runbook.Query.not_deleted()
        |> Runbook.Query.ordered_by_title_version()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, runbooks}
    end
  end

  def fetch_runbook_by_id(id, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Resolves the latest PUBLISHED runbook a caller may execute, by slug first
  (newest version of that slug) then, failing that, by a runbook row id.
  Requires `view_runbooks`; scoped to the subject's account. Returns
  `{:ok, runbook}` or `{:error, :not_found | :unauthorized}`. Drafts and
  cross-account rows read as `:not_found` — this is the resolver behind the
  MCP `execute_runbook` tool, which then dispatches through `dispatch_runbook/4`.
  """
  def fetch_published_runbook(slug_or_id, %Subject{} = subject) when is_binary(slug_or_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      case fetch_latest_published_by_slug(slug_or_id, subject) do
        {:error, :not_found} -> fetch_published_by_id(slug_or_id, subject)
        result -> result
      end
    end
  end

  @doc "Fetches one exact immutable published runbook version by slug and version."
  def fetch_published_runbook_version(slug, version, %Subject{} = subject)
      when is_binary(slug) and is_integer(version) and version > 0 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.published()
      |> Runbook.Query.by_slug(slug)
      |> Runbook.Query.by_version(version)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    end
  end

  @doc "Fetches one MCP-created draft through the caller's credential lineage."
  def fetch_mcp_draft_by_operation(operation_id, %Subject{} = subject)
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         {:ok, %{tool: :create_runbook_draft, resource_id: draft_id}} <-
           MCPOperations.fetch_recovery(operation_id, subject) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(draft_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      {:ok, _other_operation} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches one MCP runbook execution through the caller's credential lineage."
  def fetch_execution_by_operation(operation_id, %Subject{} = subject)
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         {:ok, %{tool: :execute_runbook, resource_id: execution_id}} <-
           MCPOperations.fetch_recovery(operation_id, subject) do
      RunbookExecution.Query.by_account_id(subject.account.id)
      |> RunbookExecution.Query.by_id(execution_id)
      |> Repo.fetch(RunbookExecution.Query)
    else
      {:ok, _other_operation} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches one runbook execution visible to the subject."
  def fetch_execution_by_id(execution_id, %Subject{} = subject) when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(execution_id),
         access = Accounts.runner_access_for_subject(subject),
         {:ok, execution} <-
           fetch_scoped_execution(execution_id, access, subject, false) do
      {:ok, execution}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Fetches the bounded execution result needed by console and MCP projections.

  It includes durable stages and logical items plus only the latest physical
  attempt for each item. Full attempt history remains paginated by Runs.
  """
  def fetch_execution_result(execution_id, %Subject{} = subject)
      when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(execution_id),
         access = Accounts.runner_access_for_subject(subject),
         {:ok, execution} <-
           fetch_scoped_execution(execution_id, access, subject, true),
         {:ok, runbook} <- fetch_runbook_for_execution(execution, subject),
         {:ok, attempts} <- Runs.list_latest_runbook_attempts(execution.id, subject) do
      {:ok, %{execution: execution, runbook: runbook, latest_attempts: attempts}}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Fetches the immutable runbook row retained by an execution, including soft-deleted families."
  def fetch_runbook_for_execution(%RunbookExecution{} = execution, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         :ok <- Subject.ensure_in_account(subject, execution.account_id) do
      Runbook.Query.all()
      |> Runbook.Query.by_id(execution.runbook_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    end
  end

  defp fetch_latest_published_by_slug(slug, %Subject{} = subject) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.published()
    |> Runbook.Query.by_slug(slug)
    |> Runbook.Query.latest_version()
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Runbook.Query)
  end

  defp fetch_published_by_id(id, %Subject{} = subject) do
    if Repo.valid_uuid?(id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.published()
      |> Runbook.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Changeset for the runbook editor's metadata form (title/slug/description).
  Drives `phx-change` validation + inline field errors in the LiveView; the
  row itself is persisted by `create_runbook/2` / `save_new_version/3`, which
  also validate the structured `definition`.
  """
  def change_runbook(attrs \\ %{}), do: Runbook.Changeset.form(attrs)

  # -- Mutations -------------------------------------------------------

  @doc """
  Creates a bounded runbook, always born `:draft` — incomplete canonical
  definitions may be saved, while publication remains strict.
  `Runbook.Changeset.create/3` never casts `:status`, so a client-supplied
  status is ignored. Requires manage or draft permission; returns
  `{:ok, runbook} | {:error, changeset | :unauthorized}`.
  """
  def create_runbook(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ) do
      account.id
      |> Runbook.Changeset.create(Subject.user_id(subject), attrs)
      |> insert_runbook(subject)
    end
  end

  @doc """
  Imports one strictly valid canonical v1 JSON definition as a draft in the
  subject's account. Requires manage or draft permission; returns
  `{:ok, runbook} | {:error, changeset | [Definition.issue()] | :unauthorized}`.
  """
  def import_runbook(title, encoded_definition, %Subject{account: account} = subject)
      when is_binary(title) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ),
         {:ok, definition} <- Definition.decode_json(encoded_definition) do
      attrs = %{
        "title" => title,
        "slug" => "",
        "description" => "",
        "definition" => definition
      }

      account.id
      |> Runbook.Changeset.create(Subject.user_id(subject), attrs)
      |> insert_runbook(subject)
    end
  end

  @doc """
  Creates a runbook born `:published` — the editor's one-click publish-from-new.
  Requires `manage_runbooks`; the status is decided by this named transition,
  never cast from client attrs, so the authorizer's "publish stays closed at
  the domain layer" holds structurally: `create_runbook/2` can only mint drafts,
  and this is the sole born-published path.
  """
  def create_published_runbook(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      account.id
      |> Runbook.Changeset.create_published(Subject.user_id(subject), attrs)
      |> insert_runbook(subject)
    end
  end

  defp insert_runbook(changeset, %Subject{} = subject) do
    Multi.new()
    |> Multi.insert(:runbook, changeset)
    |> Multi.insert(:audit, fn %{runbook: runbook} ->
      Audit.Events.runbook_created(subject, runbook)
    end)
    |> Repo.commit_multi(after_commit: &broadcast_runbook_created(&1.runbook))
    |> case do
      {:ok, %{runbook: runbook}} -> {:ok, runbook}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates or replays one MCP draft under its bridge operation identity."
  def create_mcp_draft(attrs, operation_id, fingerprint, %Subject{account: account} = subject)
      when is_binary(operation_id) and is_binary(fingerprint) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ) do
      id = MCPOperations.resource_id(operation_id, :create_runbook_draft, subject)
      attrs = Map.put(attrs, "id", id)

      operation_attrs = %{
        operation_id: operation_id,
        tool: :create_runbook_draft,
        fingerprint: fingerprint,
        resource_id: id,
        resource_ref: attrs["slug"]
      }

      with {:ok, multi} <-
             MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject) do
        multi =
          Multi.merge(multi, fn
            %{mcp_operation: %{fresh?: false}} ->
              Multi.new()

            %{mcp_operation: %{fresh?: true}} ->
              Multi.new()
              |> Multi.insert(
                :runbook,
                Runbook.Changeset.create(account.id, Subject.user_id(subject), attrs)
              )
              |> Multi.insert(:audit, fn %{runbook: runbook} ->
                Audit.Events.runbook_created(subject, runbook)
              end)
          end)

        with {:ok, %{mcp_operation: reservation}} <-
               Repo.commit_multi(multi, after_commit: &after_mcp_draft_committed/1),
             {:ok, runbook} <- fetch_runbook_by_id(id, subject) do
          kind = if reservation.fresh?, do: :created, else: :replay
          {:ok, kind, runbook}
        end
      end
    end
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: true}, runbook: runbook}) do
    broadcast_runbook_created(runbook)
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  # -- PubSub ----------------------------------------------------------

  @doc "Subscribe the caller to the account's runbook list changes (`{:list_changed, :runbook, …}`)."
  def subscribe_account_runbooks(account_id),
    do: Emisar.PubSub.subscribe(account_runbooks_topic(account_id))

  @doc """
  Subscribe to durable state changes for one already-authorized execution.

  The small `{:runbook_execution_updated, execution_id}` signal is never a
  result projection; subscribers re-read through `fetch_execution_result/2`.
  """
  def subscribe_execution(account_id, execution_id),
    do: Emisar.PubSub.subscribe(execution_topic(account_id, execution_id))

  def unsubscribe_execution(account_id, execution_id),
    do: Emisar.PubSub.unsubscribe(execution_topic(account_id, execution_id))

  @doc "Internal after-commit signal for one durable execution transition."
  def broadcast_execution_updated(account_id, execution_id) do
    Emisar.PubSub.broadcast(
      execution_topic(account_id, execution_id),
      {:runbook_execution_updated, execution_id}
    )
  end

  defp account_runbooks_topic(account_id), do: "account:#{account_id}:runbooks"

  defp execution_topic(account_id, execution_id),
    do: "account:#{account_id}:runbook-execution:#{execution_id}"

  defp broadcast_runbook_created(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.created", runbook.id}
    )
  end

  defp broadcast_runbook_updated(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.updated", runbook.id}
    )
  end

  defp broadcast_runbook_published(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.published", runbook.id}
    )
  end

  defp broadcast_runbook_deleted(%Runbook{} = runbook) do
    Emisar.PubSub.broadcast(
      account_runbooks_topic(runbook.account_id),
      {:list_changed, :runbook, "runbook.deleted", runbook.id}
    )
  end

  def save_new_version(%Runbook{} = old, attrs, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, old.account_id) do
      user_id = Subject.user_id(subject)

      Multi.new()
      |> Multi.insert(:runbook, Runbook.Changeset.new_version(old, user_id, attrs))
      |> Multi.insert(:audit, fn %{runbook: runbook} ->
        Audit.Events.runbook_updated(subject, old, runbook)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_updated(&1.runbook))
      |> case do
        {:ok, %{runbook: runbook}} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def publish(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &Runbook.Changeset.update(&1, %{status: :published}),
        audit: &Audit.Events.runbook_published(subject, &1),
        after_commit: &broadcast_runbook_published/1
      )
    end
  end

  @doc """
  Soft-deletes a runbook and ALL its versions (they share a slug within the
  account). Requires `manage_runbooks` and that the subject owns the runbook's
  account. Returns `{:ok, runbook}` or `{:error, :unauthorized | :not_found}`.
  """
  def delete_runbook(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      # Tombstone the whole family — a per-row delete would strand older
      # versions (each version is its own not-deleted row) in the list.
      queryable =
        Runbook.Query.not_deleted()
        |> Runbook.Query.by_account_id(runbook.account_id)
        |> Runbook.Query.by_slug(runbook.slug)
        |> Authorizer.for_subject(subject)

      Multi.new()
      |> Multi.update_all(:runbooks, queryable, set: [deleted_at: DateTime.utc_now()])
      |> Multi.insert(:audit, Audit.Events.runbook_deleted(subject, runbook))
      |> Repo.commit_multi(after_commit: fn _ -> broadcast_runbook_deleted(runbook) end)
      |> case do
        {:ok, _} -> {:ok, runbook}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Execution -------------------------------------------------------

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch.
  """
  def expand(%Runbook{definition: %{"stages" => stages}}) when is_list(stages),
    do: Enum.flat_map(stages, & &1["steps"])

  def expand(_), do: []

  @doc """
  Compiles and dispatches a published runbook through the durable stage scheduler.

  A draft stays private and unexecutable — it returns `{:error, :not_published}`.

  The compiler resolves typed inputs, runner fan-out, current trusted packs,
  and action contracts before any execution row is created. The resulting plan
  is immutable; current membership, runner scope, policy, lifecycle, trust, and
  content hash are rechecked before each physical attempt.

  MCP callers may pass their operation identity through `opts`. Matching
  operations replay before mutable preflight; conflicting fingerprints fail
  without creating another execution.
  """
  def dispatch_runbook(%Runbook{} = runbook, reason, %Subject{} = subject, opts \\ [])
      when is_binary(reason) do
    operation_id = Keyword.get(opts, :operation_id)
    operation_fingerprint = Keyword.get(opts, :operation_fingerprint)
    operation_ref = Keyword.get(opts, :operation_ref)
    input_values = Keyword.get(opts, :input_values, %{})
    selection_seed = Keyword.get_lazy(opts, :target_selection_seed, &new_target_selection_seed/0)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         :ok <- ensure_published(runbook),
         :ok <- ensure_membership(subject),
         :ok <- ensure_reason(reason) do
      if operation_id do
        dispatch_mcp_execution(
          runbook,
          reason,
          input_values,
          subject,
          operation_id,
          operation_fingerprint,
          operation_ref,
          selection_seed
        )
      else
        with {:ok, compiled} <-
               Compiler.compile(runbook.definition, input_values, selection_seed, subject) do
          Scheduler.create_execution(runbook, compiled, reason, subject)
        end
      end
    end
  end

  defp dispatch_mcp_execution(
         runbook,
         reason,
         input_values,
         subject,
         operation_id,
         fingerprint,
         operation_ref,
         selection_seed
       )
       when is_binary(operation_id) and is_binary(fingerprint) and is_binary(operation_ref) do
    execution_id = MCPOperations.resource_id(operation_id, :execute_runbook, subject)

    operation_attrs = %{
      operation_id: operation_id,
      tool: :execute_runbook,
      fingerprint: fingerprint,
      resource_id: execution_id,
      resource_ref: operation_ref
    }

    case MCPOperations.fetch_matching_replay(operation_attrs, subject) do
      {:ok, _operation} ->
        Scheduler.fetch_result(execution_id, runbook.account_id)

      {:error, :not_found} ->
        create_mcp_execution(
          runbook,
          reason,
          input_values,
          subject,
          operation_attrs,
          execution_id,
          selection_seed
        )

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch_mcp_execution(
         _runbook,
         _reason,
         _input_values,
         _subject,
         _operation_id,
         _fingerprint,
         _operation_ref,
         _selection_seed
       ),
       do: {:error, :invalid_operation}

  defp create_mcp_execution(
         runbook,
         reason,
         input_values,
         subject,
         operation_attrs,
         execution_id,
         selection_seed
       ) do
    with {:ok, compiled} <-
           Compiler.compile(runbook.definition, input_values, selection_seed, subject),
         {:ok, multi} <-
           MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject) do
      multi =
        Multi.merge(multi, fn
          %{mcp_operation: %{fresh?: false}} ->
            Multi.new()

          %{mcp_operation: %{fresh?: true, operation: operation}} ->
            Scheduler.compose_creation(
              Multi.new(),
              runbook,
              compiled,
              reason,
              subject,
              execution_id,
              operation_id: operation_attrs.operation_id,
              mcp_operation_record_id: operation.id
            )
        end)

      with {:ok, changes} <-
             Repo.commit_multi(multi,
               after_commit: &Approvals.after_runbook_execution_request_committed/1
             ) do
        reservation = changes.mcp_operation
        execution = Map.get(changes, {:runbook_execution, execution_id})

        if reservation.fresh? and match?(%RunbookExecution{status: :active}, execution),
          do: Scheduler.advance_execution(execution_id),
          else: :ok

        Scheduler.fetch_result(execution_id, runbook.account_id)
      end
    end
  end

  @doc """
  Compiles a runbook without creating an execution.

  The returned plan is the exact frozen blast radius the scheduler would use:
  stages, logical steps, selected runners, exact trusted packs, and action
  contract digests. It performs the same authorization and preflight as a
  dispatch.
  """
  def resolve_plan(%Runbook{} = runbook, %Subject{} = subject),
    do: resolve_plan(runbook, %{}, subject)

  def resolve_plan(%Runbook{} = runbook, input_values, %Subject{} = subject) do
    resolve_plan(runbook, input_values, new_target_selection_seed(), subject)
  end

  def resolve_plan(
        %Runbook{} = runbook,
        input_values,
        selection_seed,
        %Subject{} = subject
      )
      when is_binary(selection_seed) and selection_seed != "" do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         {:ok, compiled} <-
           Compiler.compile(runbook.definition, input_values, selection_seed, subject) do
      total = compiled.plan["total_items"]
      {:ok, %{plan: compiled.plan, total: total, stages: length(compiled.plan["stages"])}}
    end
  end

  @doc """
  Compiles one unsaved canonical definition for the structured editor. This is
  the same compiler used by dispatch, exposed without constructing a synthetic
  Runbook row.
  """
  def resolve_definition_plan(definition, input_values, %Subject{} = subject)
      when is_map(input_values) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         {:ok, compiled} <-
           Compiler.compile(definition, input_values, new_target_selection_seed(), subject) do
      {:ok,
       %{
         plan: compiled.plan,
         total: compiled.plan["total_items"],
         stages: length(compiled.plan["stages"])
       }}
    end
  end

  @doc "Returns a fresh server-side seed for one stable preflight and dispatch pair."
  def new_target_selection_seed, do: Crypto.random_secret()

  @doc "Validates one unsaved definition through the context-owned strict contract."
  def validate_definition(definition, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runbooks_permission()
           ) do
      Emisar.Runbooks.Definition.validate(definition)
    end
  end

  @doc """
  Runs the real compiler for an authoring preview using deterministic values
  only where a required input has no default. The preview values are never
  persisted and sensitive values are redacted by the compiler.
  """
  def preview_definition_plan(definition, %Subject{} = subject) do
    with {:ok, definition} <- validate_definition(definition, subject) do
      resolve_definition_plan(definition, authoring_preview_inputs(definition), subject)
    end
  end

  @doc "Returns the newest execution for an already-visible runbook."
  def fetch_latest_execution_for_runbook(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         access = Accounts.runner_access_for_subject(subject),
         %RunbookExecution{id: execution_id} <-
           peek_latest_scoped_execution(runbook.id, access, subject) do
      fetch_execution_result(execution_id, subject)
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Lists a bounded recent execution history for one already-visible runbook."
  def list_recent_executions_for_runbook(
        %Runbook{} = runbook,
        %Subject{} = subject,
        limit \\ 10
      )
      when is_integer(limit) and limit >= 1 and limit <= 25 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      executions =
        RunbookExecution.Query.by_runbook_id(runbook.id)
        |> RunbookExecution.Query.by_runner_access(Accounts.runner_access_for_subject(subject))
        |> RunbookExecution.Query.ordered_by_recent()
        |> RunbookExecution.Query.limit_to(limit)
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, executions}
    end
  end

  @doc "Lists a bounded recent execution history across the subject's visible runbooks."
  def list_recent_executions(%Subject{} = subject, limit \\ 5)
      when is_integer(limit) and limit >= 1 and limit <= 25 do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      executions =
        RunbookExecution.Query.all()
        |> RunbookExecution.Query.by_runner_access(Accounts.runner_access_for_subject(subject))
        |> RunbookExecution.Query.ordered_by_recent()
        |> RunbookExecution.Query.limit_to(limit)
        |> RunbookExecution.Query.with_runbook()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, executions}
    end
  end

  defp fetch_scoped_execution(execution_id, access, subject, preload?) do
    query =
      RunbookExecution.Query.by_id(execution_id)
      |> RunbookExecution.Query.by_runner_access(access)
      |> maybe_with_execution_result(preload?)

    query
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(RunbookExecution.Query)
  end

  # requested_by is part of the result projection's contract: every consumer
  # attributes the execution to its accountable human (console header, MCP
  # serialization keeps it cheap to ignore).
  defp maybe_with_execution_result(query, true) do
    query
    |> RunbookExecution.Query.with_stages_and_items()
    |> RunbookExecution.Query.with_requested_by()
  end

  defp maybe_with_execution_result(query, false), do: query

  defp peek_latest_scoped_execution(runbook_id, access, subject) do
    RunbookExecution.Query.by_runbook_id(runbook_id)
    |> RunbookExecution.Query.by_runner_access(access)
    |> RunbookExecution.Query.ordered_by_recent()
    |> RunbookExecution.Query.limit_to(1)
    |> Authorizer.for_subject(subject)
    |> Repo.peek()
  end

  defp authoring_preview_inputs(%{"inputs" => inputs}) do
    inputs
    |> Enum.filter(&(&1["required"] and not Map.has_key?(&1, "default")))
    |> Map.new(&{&1["id"], authoring_preview_value(&1)})
  end

  defp authoring_preview_value(%{"enum" => [first | _]}), do: first

  defp authoring_preview_value(%{"type" => "string"} = input) do
    String.duplicate("x", input["min_length"] || 0)
  end

  defp authoring_preview_value(%{"type" => "integer"} = input) do
    input["minimum"]
    |> then(fn minimum -> if is_number(minimum), do: ceil(minimum), else: 0 end)
    |> min_integer_maximum(input["maximum"])
  end

  defp authoring_preview_value(%{"type" => "number"} = input) do
    input["minimum"] || input["maximum"] || 0
  end

  defp authoring_preview_value(%{"type" => "boolean"}), do: false

  defp min_integer_maximum(value, maximum) when is_number(maximum),
    do: min(value, floor(maximum))

  defp min_integer_maximum(value, _maximum), do: value

  @doc "Checks whether a runbook's current trusted execution contract is visible to a subject."
  def validate_model_visible_runbook(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      Compiler.validate_availability(runbook.definition, subject)
    end
  end

  @doc """
  Cancels one visible active execution and requests cancellation of its active
  physical attempts. Terminal executions are returned unchanged.
  """
  def cancel_execution(execution_id, %Subject{} = subject) when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.cancel_run_permission()
           ),
         {:ok, execution} <- fetch_execution_by_id(execution_id, subject),
         {:ok, runbook} <- fetch_runbook_for_execution(execution, subject) do
      Scheduler.cancel_execution(execution, runbook, subject)
    end
  end

  @doc "Internal terminal-attempt callback from the Runs context."
  def action_run_settled(run), do: Emisar.Runbooks.Scheduler.action_run_settled(run)

  @doc "Internal execution-approval callback from the Approvals context."
  def approval_settled(execution_id),
    do: Emisar.Runbooks.Scheduler.approval_settled(execution_id)

  @doc "Internal execution-approval recheck used while deciding a request."
  def recheck_execution_approval(execution_id),
    do: Emisar.Runbooks.Scheduler.recheck_execution_approval(execution_id)

  @doc """
  Internal bounded runner ids for an execution approval notification. The explicit
  account scope prevents an adjacent-context notifier from turning an execution id
  into a cross-account lookup.
  """
  def runner_ids_for_execution_approval(execution_id, account_id)
      when is_binary(execution_id) and is_binary(account_id) do
    execution_query =
      RunbookExecution.Query.by_account_id(account_id)
      |> RunbookExecution.Query.by_id(execution_id)

    with true <- Repo.valid_uuid?(execution_id) and Repo.valid_uuid?(account_id),
         %RunbookExecution{} <- Repo.peek(execution_query) do
      runner_ids =
        ExecutionItem.Query.by_execution_id(execution_id)
        |> ExecutionItem.Query.select_runner_ids()
        |> Repo.all()
        |> Enum.uniq()

      {:ok, runner_ids}
    else
      _ -> {:error, :not_found}
    end
  end

  def runner_ids_for_execution_approval(_execution_id, _account_id), do: {:error, :not_found}

  @doc "Internal — activate an execution inside its final approval transaction."
  def activate_pending_approval(repo, execution_id),
    do: Emisar.Runbooks.Scheduler.activate_pending_approval(repo, execution_id)

  @doc "Internal — lock an execution before its approval request is decided."
  def lock_pending_approval(repo, execution_id),
    do: Emisar.Runbooks.Scheduler.lock_pending_approval(repo, execution_id)

  @doc "Internal — compose an approval denial or expiry into its transaction."
  def halt_pending_approval_in_multi(multi, execution_id, code, message) do
    Emisar.Runbooks.Scheduler.halt_pending_approval_in_multi(
      multi,
      execution_id,
      code,
      message
    )
  end

  @doc "Internal — exact logical-attempt identity check for the Runs context."
  def attempt_identity_current?(attrs, account_id)
      when is_map(attrs) and is_binary(account_id) do
    item =
      ExecutionItem.Query.by_id(attrs[:runbook_execution_item_id])
      |> Repo.peek()

    case item do
      %ExecutionItem{} ->
        item.account_id == account_id and
          item.runbook_execution_id == attrs[:runbook_execution_id] and
          item.runbook_execution_stage_id == attrs[:runbook_execution_stage_id] and
          item.runner_id == attrs[:runner_id] and
          item.action_id == attrs[:action_id] and
          item.pack_ref == attrs[:pack_ref] and
          item.pack_hash == attrs[:runbook_pack_hash] and
          item.status == :running and
          item.attempt_count == attrs[:attempt_number]

      nil ->
        false
    end
  end

  def attempt_identity_current?(_attrs, _account_id), do: false

  @doc "Internal — confirm an action approval still belongs to the current active attempt."
  def ensure_attempt_approvable(repo, run),
    do: Emisar.Runbooks.Scheduler.ensure_attempt_approvable(repo, run)

  @doc "Internal bounded recovery sweep for the Runbooks recurrent job."
  def recover_due, do: Scheduler.recover_due()

  # -- Authorization ---------------------------------------------------

  @doc "True when the subject may view runbooks (the console nav + section gate)."
  def subject_can_view_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.view_runbooks_permission())

  @doc "Whether `subject` may manage runbooks (admin+)."
  def subject_can_manage_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runbooks_permission())

  @doc "Whether `subject` may cancel a visible runbook execution."
  def subject_can_cancel_execution?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Emisar.Runs.Authorizer.cancel_run_permission())

  defp ensure_published(%Runbook{status: :published}), do: :ok
  defp ensure_published(%Runbook{}), do: {:error, :not_published}

  defp ensure_membership(%Subject{membership_id: id}) when is_binary(id), do: :ok
  defp ensure_membership(_), do: {:error, :membership_required}

  defp ensure_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, :reason_required}, else: :ok
  end
end

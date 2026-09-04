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
  alias Emisar.{Accounts, ApiKeys, Approvals, Audit, Auth, Crypto, MCPOperations, Repo, Runs}
  alias Emisar.Auth.Subject
  alias Emisar.{Catalog, Runners}
  alias Emisar.Runbooks.{Authoring, Authorizer, Compiler, Definition, DefinitionDiff}
  alias Emisar.Runbooks.{EditorProjection, ExecutionItem, ExecutionProjection, Naming, Release}
  alias Emisar.Runbooks.{Runbook, RunbookExecution, Scheduler}
  alias Emisar.SafeText
  alias Emisar.Users

  # One runbook list page is 35 rows; 64 bounds the batch without capping the
  # page it serves.
  @max_risk_runbook_ids 64
  # The published `<slug>@<version>` identity a model executes by. The version is
  # bounded to 9 digits because it is String.to_integer'd into an int4 column: an
  # unbounded `[0-9]*` accepted 94 digits from a schema-valid ref, and Postgrex
  # then RAISED an encode error rather than returning one — a 500 with a
  # stacktrace instead of a JSON-RPC error frame, on a boundary whose caller is
  # an untrusted LLM and which allows 300 requests a minute.
  @runbook_ref ~r/\A([a-z][a-z0-9_-]{0,79})@([1-9][0-9]{0,8})\z/
  # Mirrored at compile time so a schema change reaches every consumer that
  # embeds it in its own compile-time attributes.
  @definition_schema Definition.schema()

  @typedoc "One authoring problem with a stable code, JSON Pointer path, and message."
  @type definition_issue :: %{code: String.t(), path: String.t(), message: String.t()}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    children = [job_module("AdvanceExecutions"), job_module("ExecutionRetention")]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp job_module(name), do: Module.safe_concat([__MODULE__, "Jobs", name])

  # -- Definition contract ---------------------------------------------

  @doc "The decoded, immutable v1 machine schema every authoring surface publishes."
  @spec definition_schema() :: map()
  def definition_schema, do: @definition_schema

  @doc "One trusted first-party definition limit, by its atom name."
  @spec definition_limit!(atom()) :: pos_integer()
  def definition_limit!(name) when is_atom(name), do: Definition.limit!(name)

  @doc """
  One stored-byte ceiling for a runbook's row metadata, by its atom name.

  A projection budget can only be derived from bounds measured in the same unit
  it spends, so the metadata columns publish bytes rather than characters.
  """
  @spec metadata_limit!(:title_bytes | :description_bytes) :: pos_integer()
  def metadata_limit!(:title_bytes), do: Runbook.Changeset.max_title_bytes()
  def metadata_limit!(:description_bytes), do: Runbook.Changeset.max_description_bytes()

  @doc """
  Decodes and strictly validates one bounded canonical v1 JSON document.
  Returns `{:ok, definition} | {:error, [definition_issue()]}`.
  """
  @spec decode_definition_json(term()) :: {:ok, map()} | {:error, [definition_issue()]}
  def decode_definition_json(encoded), do: Definition.decode_json(encoded)

  @doc """
  Validates one already-decoded definition against the strict publication and
  execution contract. Returns `{:ok, definition} | {:error, [definition_issue()]}`.
  """
  @spec validate_definition(term()) :: {:ok, map()} | {:error, [definition_issue()]}
  def validate_definition(definition), do: Definition.validate(definition)

  @doc """
  Validates the safety envelope a persisted draft must satisfy — incomplete but
  still canonical and bounded. Returns
  `{:ok, definition} | {:error, [definition_issue()]}`.
  """
  @spec validate_draft_definition(term()) :: {:ok, map()} | {:error, [definition_issue()]}
  def validate_draft_definition(definition), do: Definition.validate_draft(definition)

  @doc "Stable SHA-256 identity for one JSON-compatible definition."
  @spec definition_digest(map()) :: String.t()
  def definition_digest(definition), do: Definition.digest(definition)

  @doc "The canonical v1 definition built from one lossless typed editor command."
  @spec build_definition_v1(Authoring.command()) :: map()
  def build_definition_v1(command), do: Authoring.build_v1(command)

  @doc """
  One editor argument row reconciled against the action descriptor it binds:
  the descriptor owns the metadata, the operator keeps their source and value.
  """
  @spec sync_definition_argument(map(), Authoring.argument() | nil) :: Authoring.argument()
  def sync_definition_argument(spec, existing), do: Authoring.sync_argument(spec, existing)

  @doc """
  The operator's slug candidate when it carries a value, otherwise one derived
  from the title. An invalid candidate is returned verbatim so the changeset
  reports it rather than silently replacing what they typed.
  """
  @spec resolve_slug(String.t() | nil, String.t() | nil) :: String.t()
  def resolve_slug(title, candidate), do: Naming.resolve_slug(title, candidate)

  # -- Reads -----------------------------------------------------------

  @doc "The Runbooks table's `%Repo.Filter{}` list."
  def runbook_filters, do: Runbook.Query.filters()

  @doc """
  Lists one row per runbook. Requires `view_runbooks`; scoped to the subject's
  account. Returns
  `{:ok, [runbook], %Metadata{}} | {:error, :unauthorized | :invalid_cursor}`.
  """
  def list_runbooks(%Subject{} = subject, opts \\ []) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.ordered_by_title()
      |> Authorizer.for_subject(subject)
      |> Repo.list(Runbook.Query, opts)
    end
  end

  @doc """
  Line diff carrying one definition forward to another.

  Pure — the caller already holds both rows, and the context owns the boundary
  because `DefinitionDiff` is an internal module the web may not reach.
  """
  def definition_diff(previous_definition, definition)
      when is_map(previous_definition) and is_map(definition),
      do: DefinitionDiff.build(previous_definition, definition)

  @doc """
  `%{runbook_id => most-severe step risk}` for at most #{@max_risk_runbook_ids}
  already-listed runbooks — the risk tier each list row shows, resolved for the
  whole page in one catalog read rather than a query per row. Requires
  `view_runbooks`; visibility is re-checked by id (a held struct cannot widen
  it) without re-fetching the wide definition rows the caller just listed, so a
  deleted or cross-account runbook is simply absent from the map.

  Every visible runbook IS a key: one whose steps include an action no runner
  the caller can reach advertises maps to `nil`, so the row shows no pill
  rather than the worst of the steps we happened to resolve. Returns
  `{:ok, %{runbook_id => risk | nil}}`, `{:error, :unauthorized}`, or
  `{:error, :too_many_runbooks}`.
  """
  def risk_by_runbooks(runbooks, %Subject{} = subject)
      when is_list(runbooks) and length(runbooks) <= @max_risk_runbook_ids do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      visible_ids = visible_runbook_ids(Enum.map(runbooks, & &1.id), subject)
      visible_runbooks = Enum.filter(runbooks, &MapSet.member?(visible_ids, &1.id))

      action_ids =
        visible_runbooks
        |> Enum.flat_map(&step_action_ids/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      risk_by_action =
        case Catalog.risk_by_action_ids(action_ids, subject) do
          {:ok, risks} -> risks
          {:error, _reason} -> %{}
        end

      {:ok, Map.new(visible_runbooks, &{&1.id, runbook_risk(&1, risk_by_action)})}
    end
  end

  def risk_by_runbooks(_runbooks, %Subject{}), do: {:error, :too_many_runbooks}

  defp visible_runbook_ids(runbook_ids, %Subject{} = subject) do
    ids = Enum.filter(runbook_ids, &Repo.valid_uuid?/1)

    Runbook.Query.not_deleted()
    |> Runbook.Query.by_ids(ids)
    |> Runbook.Query.select_ids()
    |> Authorizer.for_subject(subject)
    |> Repo.all()
    |> MapSet.new()
  end

  defp runbook_risk(%Runbook{} = runbook, risk_by_action) do
    runbook
    |> step_action_ids()
    |> Enum.map(&Map.get(risk_by_action, &1))
    |> Catalog.max_risk()
  end

  # Steps name their action as `action_id` or `action` interchangeably, same as
  # the dispatch path; a step naming neither stays unresolved.
  defp step_action_ids(%Runbook{} = runbook),
    do: runbook |> expand() |> Enum.map(&step_action_id/1)

  defp step_action_id(%{"action_id" => action_id}) when is_binary(action_id), do: action_id
  defp step_action_id(%{"action" => action}) when is_binary(action), do: action
  defp step_action_id(_step), do: nil

  @doc """
  Lists every live runbook a model may discover. Requires `view_runbooks`;
  scoped to the subject's account, then narrowed to the rows whose CURRENT
  execution contract is still available. Returns
  `{:ok, [runbook]} | {:error, :unauthorized}`.
  """
  def list_model_visible_runbooks(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      runbooks =
        Runbook.Query.not_deleted()
        |> Runbook.Query.live()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      # One batched compile for the whole page: the fleet, trust and contract
      # facts are account-wide, so asking per runbook made discovery cost a
      # fleet read and a catalog resolution for every row it listed.
      with {:ok, verdicts} <-
             Compiler.validate_availability_all(Enum.map(runbooks, & &1.definition), subject) do
        {:ok, runbooks |> Enum.zip(verdicts) |> Enum.flat_map(&model_visible_runbook/1)}
      end
    end
  end

  defp model_visible_runbook({%Runbook{} = runbook, :ok}), do: [runbook]
  defp model_visible_runbook({%Runbook{}, {:error, _issues}}), do: []

  @doc """
  Lists every runbook carrying an unpublished change a model may revise.

  Unlike live discovery, draft discovery does not require current target
  availability: an unavailable draft must remain reachable so its author can
  repair it. Requires `view_runbooks`; scoped to the subject's account.
  """
  def list_model_draft_runbooks(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      runbooks =
        Runbook.Query.not_deleted()
        |> Runbook.Query.has_draft()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, runbooks}
    end
  end

  @doc """
  Fetches the live runbook one slug names, for a model to read. Requires
  `view_runbooks`; scoped to the subject's account. Returns
  `{:ok, runbook} | {:error, :not_found | :unauthorized}` — a never-published,
  cross-account, missing, or currently unavailable runbook is all `:not_found`,
  so discovery never confirms a runbook the caller may not execute.
  """
  def fetch_model_visible_runbook(slug, %Subject{} = subject) when is_binary(slug) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         {:ok, runbook} <- fetch_live_runbook_by_slug(slug, subject) do
      if model_visible?(runbook, subject), do: {:ok, runbook}, else: {:error, :not_found}
    end
  end

  @doc """
  Fetches the unpublished change one slug carries.

  A runbook with nothing unpublished, a deleted one, and a foreign-account one
  are all `:not_found`. Current runner and catalog availability is deliberately
  not a read gate because the caller may be inspecting the draft to repair it.
  """
  def fetch_model_runbook_draft(slug, %Subject{} = subject) when is_binary(slug) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_slug(slug)
      |> Runbook.Query.has_draft()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Runbook.Query)
    end
  end

  defp fetch_live_runbook_by_slug(slug, %Subject{} = subject) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.by_slug(slug)
    |> Runbook.Query.live()
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Runbook.Query)
  end

  # Discovery answers one question — could this runbook run right now? Every
  # availability failure (missing target, untrusted or retired pack, changed
  # contract) is the same answer to a model: it isn't there.
  defp model_visible?(%Runbook{} = runbook, %Subject{} = subject),
    do: Compiler.validate_availability(runbook.definition, subject) == :ok

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

  @doc "Fetches one account-scoped runbook execution visible to the subject."
  def fetch_execution_by_id(execution_id, %Subject{} = subject) when is_binary(execution_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(subject, Authorizer.view_runbooks_permission()),
         true <- Repo.valid_uuid?(execution_id) do
      RunbookExecution.Query.by_id(execution_id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(RunbookExecution.Query)
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
         {:ok, execution} <- fetch_execution_result_row(execution_id, subject),
         {:ok, runbook} <- fetch_runbook_for_execution(execution, subject),
         {:ok, attempts} <- Runs.list_latest_runbook_attempts(execution.id, subject) do
      {:ok, %{execution: execution, runbook: runbook, latest_attempts: attempts}}
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Projects one `fetch_execution_result/2` result into ordered execution, stage,
  and item facts.

  Pure — the caller's fetch already authorized and scoped these rows, so this
  runs no query and takes no `%Subject{}`. It resolves the status an item
  inherits from its stage or execution, states the one blocking cause, and
  redacts every value the frozen output plan does not prove public, so no
  caller can render, hash, or size a sensitive one.
  """
  @spec execution_projection(map()) :: ExecutionProjection.t()
  def execution_projection(%{execution: %RunbookExecution{}} = result),
    do: ExecutionProjection.build(result)

  @doc """
  Fetches the runbook row an execution belongs to, including soft-deleted ones.

  Identity only — title and slug for navigation. What the execution actually ran
  is its own `definition` snapshot, because the runbook row moves on at publish.
  """
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

  @doc """
  Changeset for the runbook editor's metadata form (title/slug/description).
  Drives `phx-change` validation + inline field errors in the LiveView; the
  row itself is persisted by `create_runbook/2` / `save_draft/4`, which also
  validate the structured definition.
  """
  def change_runbook(attrs \\ %{}), do: Runbook.Changeset.form(attrs)

  # -- Mutations -------------------------------------------------------

  @doc """
  Creates a runbook whose whole content is its first, never-published draft.

  Nothing is live until someone publishes: `live_version` and `definition` stay
  null, so an incomplete canonical definition may be saved while publication
  remains strict. Requires author or draft permission, and every step named in
  the draft must sit inside the author's own runner and pack access; returns
  `{:ok, runbook} | {:error, changeset | :target_out_of_scope | :pack_out_of_scope | :unauthorized}`.
  """
  def create_runbook(attrs, %Subject{account: account} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.author_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ),
         changeset = Runbook.Changeset.create(account.id, Subject.user_id(subject), attrs),
         :ok <- ensure_authored_changeset_in_access(changeset, subject) do
      insert_runbook(changeset, subject)
    end
  end

  @doc """
  Imports one strictly valid canonical v1 JSON definition as a new runbook's
  first draft. Requires author or draft permission, and every step must sit
  inside the author's own runner and pack access; returns
  `{:ok, runbook} | {:error, changeset | [Definition.issue()] | :target_out_of_scope | :pack_out_of_scope | :unauthorized}`.
  """
  def import_runbook(title, encoded_definition, %Subject{account: account} = subject)
      when is_binary(title) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.author_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ),
         {:ok, definition} <- Definition.decode_json(encoded_definition),
         attrs = %{
           "title" => title,
           "slug" => "",
           "description" => "",
           "draft_definition" => definition
         },
         changeset = Runbook.Changeset.create(account.id, Subject.user_id(subject), attrs),
         :ok <- ensure_authored_changeset_in_access(changeset, subject) do
      insert_runbook(changeset, subject)
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

  @doc """
  Creates or replays one MCP runbook draft under its operation identity.

  `facts` carries the model's exact authoring intent: `:operation_id`,
  `:title`, the already-normalized `:slug`, `:description`, and `:definition`.
  Requires manage or draft runbooks, and every step must sit inside the
  minting member's own runner and pack access.

  The operation is reserved first; only the fresh winner validates the
  definition and writes the draft, so a rejected definition rolls the
  reservation back with it and an exact replay re-reads the committed draft
  without revalidating. Returns `{:ok, :created | :replay, runbook}`,
  `{:error, :operation_conflict}`, `{:error, :operation_incomplete}`, the
  ordered definition issues, or
  `{:error, :target_out_of_scope | :pack_out_of_scope | :unauthorized}`.
  """
  def create_or_replay_mcp_draft(
        %{operation_id: operation_id} = facts,
        %Subject{actor: %ApiKeys.ApiKey{}} = subject
      )
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ) do
      id = MCPOperations.resource_id(operation_id, :create_runbook_draft, subject)
      commit_mcp_draft(facts, id, mcp_draft_operation_attrs(facts, id), subject)
    end
  end

  def create_or_replay_mcp_draft(_facts, %Subject{}), do: {:error, :unauthorized}

  defp mcp_draft_operation_attrs(facts, id) do
    fingerprint =
      MCPOperations.mutation_fingerprint("create_runbook_draft", %{
        "title" => facts.title,
        "slug" => facts.slug,
        "description" => facts.description,
        "definition" => facts.definition
      })

    %{
      operation_id: facts.operation_id,
      tool: :create_runbook_draft,
      fingerprint: fingerprint,
      resource_id: id,
      resource_ref: facts.slug
    }
  end

  defp commit_mcp_draft(facts, id, operation_attrs, %Subject{account: account} = subject) do
    with {:ok, multi} <- MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject),
         multi =
           Multi.merge(multi, fn
             %{mcp_operation: %{fresh?: false}} ->
               Multi.new()

             %{mcp_operation: %{fresh?: true}} ->
               Multi.new()
               |> Multi.run(:definition, fn _repo, _changes ->
                 facts.definition |> Definition.validate() |> authored_definition(subject)
               end)
               |> Multi.insert(:runbook, fn %{definition: definition} ->
                 attrs = mcp_draft_attrs(facts, definition, id)
                 Runbook.Changeset.create(account.id, Subject.user_id(subject), attrs)
               end)
               |> Multi.insert(:audit, fn %{runbook: runbook} ->
                 Audit.Events.runbook_created(subject, runbook)
               end)
           end),
         {:ok, %{mcp_operation: reservation}} <-
           Repo.commit_multi(multi, after_commit: &after_mcp_draft_committed/1),
         {:ok, runbook} <- fetch_mcp_draft(id, subject) do
      {:ok, if(reservation.fresh?, do: :created, else: :replay), runbook}
    else
      {:error, %Ecto.Changeset{} = changeset} -> map_derived_id_conflict(changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  # The MCP resource id is derived from the operation; past the 24h dedup window a
  # re-derived id collides with the still-living runbook/execution PK. Present that
  # as an operation conflict, never a raw changeset (or an Ecto.ConstraintError).
  defp map_derived_id_conflict(%Ecto.Changeset{errors: errors} = changeset) do
    id_conflict? =
      Enum.any?(errors, fn
        {:id, {_message, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    if id_conflict?, do: {:error, :operation_conflict}, else: {:error, changeset}
  end

  defp mcp_draft_attrs(facts, definition, id) do
    %{
      "id" => id,
      "title" => facts.title,
      "slug" => facts.slug,
      "description" => facts.description,
      "draft_definition" => definition
    }
  end

  defp fetch_mcp_draft(id, subject) do
    case fetch_runbook_by_id(id, subject) do
      {:ok, runbook} -> {:ok, runbook}
      {:error, :not_found} -> {:error, :operation_incomplete}
      other -> other
    end
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: true}, runbook: runbook}) do
    broadcast_runbook_created(runbook)
  end

  defp after_mcp_draft_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  @doc """
  Updates or replays one runbook's single draft under its operation identity.

  `facts` carries the model's exact authoring intent: `:operation_id`, the
  `:slug` it read, the `:definition_sha256` it read (the optimistic authoring
  lock), `:title`, `:description`, and `:definition`. The runbook itself owns
  the operation's resource identity, so a replay re-reads the same row.

  Requires manage or draft runbooks, and every step the update writes must sit
  inside the minting member's own runner and pack access. Publishing remains a
  separate human-only transition. Returns `{:ok, :created | :replay, runbook}`,
  `{:error, :draft_changed}`, `{:error, :not_found}`,
  `{:error, :operation_conflict}`, `{:error, :operation_incomplete}`, the
  ordered definition issues, or
  `{:error, :target_out_of_scope | :pack_out_of_scope | :unauthorized}`.
  """
  def create_or_replay_mcp_draft_update(
        %{operation_id: operation_id} = facts,
        %Subject{actor: %ApiKeys.ApiKey{}} = subject
      )
      when is_binary(operation_id) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             {:one_of,
              [Authorizer.manage_runbooks_permission(), Authorizer.draft_runbooks_permission()]}
           ),
         {:ok, runbook} <- fetch_runbook_by_slug(facts.slug, subject) do
      attrs = mcp_draft_update_operation_attrs(facts, runbook.id)
      commit_mcp_draft_update(facts, runbook.id, attrs, subject)
    end
  end

  def create_or_replay_mcp_draft_update(_facts, %Subject{}), do: {:error, :unauthorized}

  defp mcp_draft_update_operation_attrs(facts, id) do
    fingerprint =
      MCPOperations.mutation_fingerprint("update_runbook_draft", %{
        "slug" => facts.slug,
        "definition_sha256" => facts.definition_sha256,
        "title" => facts.title,
        "description" => facts.description,
        "definition" => facts.definition
      })

    %{
      operation_id: facts.operation_id,
      tool: :update_runbook_draft,
      fingerprint: fingerprint,
      resource_id: id,
      resource_ref: facts.slug
    }
  end

  defp commit_mcp_draft_update(facts, id, operation_attrs, %Subject{} = subject) do
    with {:ok, multi} <- MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject),
         multi =
           Multi.merge(multi, fn
             %{mcp_operation: %{fresh?: false}} ->
               Multi.new()

             %{mcp_operation: %{fresh?: true}} ->
               compose_fresh_mcp_draft_update(facts, id, subject)
           end),
         {:ok, %{mcp_operation: reservation}} <-
           Repo.commit_multi(multi, after_commit: &after_mcp_draft_update_committed/1),
         {:ok, runbook} <- fetch_mcp_draft(id, subject) do
      {:ok, if(reservation.fresh?, do: :created, else: :replay), runbook}
    end
  end

  defp compose_fresh_mcp_draft_update(facts, id, %Subject{} = subject) do
    Multi.new()
    |> Multi.run(:source_runbook, fn repo, _changes ->
      fetch_locked_draft_source(facts, id, subject, repo)
    end)
    |> Multi.run(:definition, fn _repo, _changes ->
      facts.definition |> Definition.validate_draft() |> authored_definition(subject)
    end)
    |> Multi.update(:runbook, fn %{source_runbook: source, definition: definition} ->
      attrs = %{
        "title" => facts.title,
        "description" => facts.description,
        "draft_definition" => definition
      }

      Runbook.Changeset.draft(source, attrs)
    end)
    |> Multi.insert(:audit, fn %{source_runbook: source, runbook: runbook} ->
      Audit.Events.runbook_updated(subject, source, runbook)
    end)
  end

  defp fetch_locked_draft_source(facts, id, %Subject{} = subject, repo) do
    queryable =
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(id)
      |> Runbook.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    with {:ok, runbook} <- repo.fetch(queryable, Runbook.Query),
         true <- editing_digest(runbook) == facts.definition_sha256 do
      {:ok, runbook}
    else
      false -> {:error, :draft_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp after_mcp_draft_update_committed(%{mcp_operation: %{fresh?: true}, runbook: runbook}) do
    broadcast_runbook_updated(runbook)
  end

  defp after_mcp_draft_update_committed(%{mcp_operation: %{fresh?: false}}), do: :ok

  @doc """
  Saves the runbook's single mutable draft, along with its title and description.

  `base_sha` is the digest of what the editing surface read — the unpublished
  change when there was one, otherwise the live release. It is compared against
  the locked row inside the transaction, so an edit written on top of someone
  else's is refused as `{:error, :draft_changed}` rather than silently
  overwriting it. The slug is frozen once a release exists.

  Requires `author_runbooks`, that the subject owns the runbook's account, and
  that every step the save writes sits inside the author's own runner and pack
  access — judged on the locked row, so an access narrowed after the editor
  loaded is what decides. Returns
  `{:ok, runbook} | {:error, changeset | :draft_changed | :target_out_of_scope | :pack_out_of_scope | :unauthorized | :not_found}`.
  """
  def save_draft(%Runbook{} = runbook, attrs, base_sha, %Subject{} = subject)
      when is_binary(base_sha) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.author_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &save_draft_when_current(&1, attrs, base_sha, subject),
        audit: &Audit.Events.runbook_updated(subject, &2.data, &1),
        after_commit: &broadcast_runbook_updated/1
      )
    end
  end

  defp save_draft_when_current(%Runbook{} = loaded_runbook, attrs, base_sha, %Subject{} = subject) do
    if editing_digest(loaded_runbook) == base_sha do
      changeset = Runbook.Changeset.draft(loaded_runbook, attrs)

      case ensure_authored_changeset_in_access(changeset, subject) do
        :ok -> changeset
        {:error, reason} -> reason
      end
    else
      :draft_changed
    end
  end

  @doc """
  Publishes the runbook's draft as its next release.

  Mints release N = the previous `live_version` + 1 into the append-only log,
  promotes the draft to what is live, and clears it. Readiness is rechecked
  inside the transaction against the locked row's own draft — never a
  caller-held snapshot — so a stale editor preview cannot publish what current
  state refuses. Requires `author_runbooks`, that the subject owns the
  runbook's account, and that every step of the locked row's draft sits inside
  the publisher's own runner and pack access. Returns
  `{:ok, runbook} | {:error, changeset | [Definition.issue()] | :no_draft | :target_out_of_scope | :pack_out_of_scope | :unauthorized | :not_found}`.
  """
  def publish_draft(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.author_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      Multi.new()
      |> Multi.run(:locked_runbook, fn repo, _changes ->
        fetch_locked_runbook(runbook.id, subject, repo)
      end)
      |> Multi.run(:definition, fn _repo, %{locked_runbook: loaded_runbook} ->
        publishable_draft(loaded_runbook, subject)
      end)
      |> Multi.insert(:release, &release_changeset(&1, subject))
      |> Multi.update(:runbook, fn changes ->
        %{locked_runbook: loaded_runbook, definition: definition, release: release} = changes
        Runbook.Changeset.publish(loaded_runbook, definition, release.version)
      end)
      |> Multi.insert(:audit, fn %{runbook: published, release: release} ->
        Audit.Events.runbook_published(subject, published, release)
      end)
      |> Repo.commit_multi(after_commit: &broadcast_runbook_published(&1.runbook))
      |> case do
        {:ok, %{runbook: published}} -> {:ok, published}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp publishable_draft(%Runbook{draft_definition: nil}, %Subject{}), do: {:error, :no_draft}

  # The access gate is stated separately from readiness on purpose: the compile
  # below would also refuse an out-of-scope target, but only because it resolves
  # against the publisher's scoped fleet — which makes a SECURITY property ride
  # on an availability check and answers a scope problem with "unknown target".
  defp publishable_draft(%Runbook{} = loaded_runbook, %Subject{} = subject) do
    with :ok <- ensure_definition_in_author_access(loaded_runbook.draft_definition, subject) do
      publication_readiness(loaded_runbook.draft_definition, subject)
    end
  end

  defp release_changeset(%{locked_runbook: loaded_runbook, definition: definition}, subject) do
    Release.Changeset.create(%{
      account_id: loaded_runbook.account_id,
      runbook_id: loaded_runbook.id,
      version: (loaded_runbook.live_version || 0) + 1,
      title: loaded_runbook.title,
      description: loaded_runbook.description,
      definition: definition,
      definition_sha256: Definition.digest(definition),
      published_by_id: Subject.user_id(subject)
    })
  end

  # The authoritative publish gate — the same rule the editor's preview
  # proxies: the strict definition contract plus a full current-state compile
  # (targets, trust, contracts, bindings, policy) using deterministic
  # authoring-preview inputs. Runs inside the publishing transaction so its
  # catalog reads share the commit's snapshot.
  defp publication_readiness(definition, %Subject{} = subject) do
    with {:ok, definition} <- Definition.validate(definition),
         {:ok, _compiled} <-
           Compiler.compile(
             definition,
             authoring_preview_inputs(definition),
             new_target_selection_seed(),
             subject
           ) do
      {:ok, definition}
    end
  end

  @doc """
  Drops the runbook's unpublished change, leaving the live release running.

  A runbook that has never been published is all draft, so there is nothing to
  fall back to: it answers `{:error, :never_published}` and stays editable.
  Requires `author_runbooks` and that the subject owns the runbook's account.
  No scope gate: a discard writes no step, so it reaches nothing the author
  could not already reach — it drops a pending change and restores the release.
  Returns
  `{:ok, runbook} | {:error, :never_published | :no_draft | :unauthorized | :not_found}`.
  """
  def discard_draft(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.author_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &discard_draft_when_live/1,
        audit: &Audit.Events.runbook_updated(subject, &2.data, &1),
        after_commit: &broadcast_runbook_updated/1
      )
    end
  end

  defp discard_draft_when_live(%Runbook{live_version: nil}), do: :never_published
  defp discard_draft_when_live(%Runbook{draft_definition: nil}), do: :no_draft

  defp discard_draft_when_live(%Runbook{} = loaded_runbook),
    do: Runbook.Changeset.discard_draft(loaded_runbook)

  @doc """
  Soft-deletes a runbook. Its releases are retained — they are the record of
  what the approved procedure was while it existed. Requires `manage_runbooks`
  and that the subject owns the runbook's account. Returns
  `{:ok, runbook}` or `{:error, :unauthorized | :not_found}`.
  """
  def delete_runbook(%Runbook{} = runbook, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.manage_runbooks_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id) do
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(runbook.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Runbook.Query,
        with: &Runbook.Changeset.delete/1,
        audit: &Audit.Events.runbook_deleted(subject, &1),
        after_commit: &broadcast_runbook_deleted/1
      )
    end
  end

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

  # -- Execution -------------------------------------------------------

  @doc """
  Expand a runbook into the ordered list of step descriptors that the
  cloud's executor will dispatch.

  Reads the live release, falling back to the draft while nothing is live yet.
  """
  def expand(%Runbook{} = runbook), do: runbook |> current_definition() |> expand_definition()

  @doc """
  Compiles and dispatches a runbook's live release through the durable stage
  scheduler.

  A runbook with nothing published stays unexecutable — it returns
  `{:error, :not_live}`.

  The compiler resolves typed inputs, runner fan-out, current trusted packs,
  and action contracts before any execution row is created. The resulting plan
  is immutable; current membership, runner scope, policy, lifecycle, trust, and
  content hash are rechecked before each physical attempt.
  """
  def dispatch_runbook(%Runbook{} = runbook, reason, %Subject{} = subject, opts \\ [])
      when is_binary(reason) do
    input_values = Keyword.get(opts, :input_values, %{})
    selection_seed = Keyword.get_lazy(opts, :target_selection_seed, &new_target_selection_seed/0)

    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Emisar.Runs.Authorizer.dispatch_run_permission()
           ),
         :ok <- Subject.ensure_in_account(subject, runbook.account_id),
         :ok <- ensure_live(runbook),
         :ok <- ensure_membership(subject),
         :ok <- ensure_reason(reason),
         {:ok, compiled} <-
           Compiler.compile(runbook.definition, input_values, selection_seed, subject) do
      Scheduler.create_execution(runbook, compiled, reason, subject)
    end
  end

  @doc """
  Creates or replays one MCP runbook execution under its operation identity.

  `facts` carries the model's exact call: `:operation_id`, `:reason`,
  `:input_values`, and either the `:runbook_ref` it means to run or, with
  `allow_draft: true`, the `:slug` plus the `:definition_sha256` of the exact
  draft content it consents to.

  Published execution requires dispatch permission and the ref MUST name the
  live release — an older number is `{:error, :not_live}`, never a silent
  redirect to current content. Explicit draft execution also requires
  draft-authoring permission and runs only the draft whose digest the caller
  named.

  The operation is reserved first; only the fresh winner resolves the runbook,
  rechecks membership, reason, and current scope, seeds target selection,
  compiles the immutable plan, and composes the execution in the same
  transaction — so a rejected preflight rolls the reservation back with it. An
  exact replay re-reads the committed execution without touching current
  runbook or catalog state. Returns
  `{:ok, :created | :replay, execution}`, `{:error, :operation_conflict}`,
  `{:error, :operation_incomplete}`, or the first rejection.
  """
  def create_or_replay_mcp_execution(
        %{operation_id: operation_id} = facts,
        %Subject{actor: %ApiKeys.ApiKey{}} = subject
      )
      when is_binary(operation_id) do
    kind = mcp_execution_kind(facts)

    with :ok <- ensure_mcp_execution_permissions(kind, subject) do
      execution_id = MCPOperations.resource_id(operation_id, :execute_runbook, subject)
      operation_attrs = mcp_execution_operation_attrs(facts, execution_id, kind)
      commit_mcp_execution(facts, execution_id, operation_attrs, kind, subject)
    end
  end

  def create_or_replay_mcp_execution(_facts, %Subject{}), do: {:error, :unauthorized}

  defp mcp_execution_kind(%{allow_draft: true}), do: :draft_test
  defp mcp_execution_kind(_facts), do: :published

  defp ensure_mcp_execution_permissions(:published, %Subject{} = subject) do
    Auth.Authorizer.ensure_has_permissions(
      subject,
      Emisar.Runs.Authorizer.dispatch_run_permission()
    )
  end

  defp ensure_mcp_execution_permissions(:draft_test, %Subject{} = subject) do
    Auth.Authorizer.ensure_has_permissions(subject, [
      Authorizer.draft_runbooks_permission(),
      Emisar.Runs.Authorizer.dispatch_run_permission()
    ])
  end

  defp mcp_execution_operation_attrs(facts, execution_id, kind) do
    ref = mcp_execution_ref(facts, kind)

    fingerprint =
      MCPOperations.mutation_fingerprint("execute_runbook", %{
        "runbook_ref" => ref,
        "allow_draft" => kind == :draft_test,
        "definition_sha256" => facts[:definition_sha256],
        "reason" => facts.reason,
        "input_values" => facts.input_values
      })

    %{
      operation_id: facts.operation_id,
      tool: :execute_runbook,
      fingerprint: fingerprint,
      resource_id: execution_id,
      resource_ref: ref
    }
  end

  # A draft has no release number to name, so its consent is the slug plus the
  # exact content digest carried in the fingerprint beside it.
  defp mcp_execution_ref(facts, :draft_test), do: facts.slug
  defp mcp_execution_ref(facts, :published), do: facts.runbook_ref

  defp commit_mcp_execution(
         facts,
         execution_id,
         operation_attrs,
         kind,
         %Subject{} = subject
       ) do
    with {:ok, multi} <- MCPOperations.reserve_in_multi(Multi.new(), operation_attrs, subject),
         multi =
           Multi.merge(multi, fn
             %{mcp_operation: %{fresh?: false}} ->
               Multi.new()

             %{mcp_operation: %{fresh?: true, operation: operation}} ->
               compose_fresh_mcp_execution(facts, execution_id, operation, kind, subject)
           end),
         {:ok, changes} <-
           Repo.commit_multi(multi,
             after_commit: &Approvals.after_runbook_execution_request_committed/1
           ) do
      settle_mcp_execution(changes, execution_id, subject)
    else
      {:error, %Ecto.Changeset{} = changeset} -> map_derived_id_conflict(changeset)
      {:error, reason} -> {:error, reason}
    end
  end

  # Every mutable fact an execution freezes — which release the ref still names,
  # the exact draft content consented to, membership scope, the compiled plan —
  # is resolved by the fresh winner only, inside the reservation's own
  # transaction.
  defp compose_fresh_mcp_execution(facts, execution_id, operation, kind, subject) do
    with {:ok, runbook} <- fetch_runbook_for_mcp_execution(facts, kind, subject),
         :ok <- ensure_membership(subject),
         :ok <- ensure_reason(facts.reason),
         definition = dispatched_definition(runbook, kind),
         {:ok, compiled} <-
           Compiler.compile(
             definition,
             facts.input_values,
             new_target_selection_seed(),
             subject
           ) do
      Scheduler.compose_creation(
        Multi.new(),
        runbook,
        compiled,
        facts.reason,
        subject,
        execution_id,
        operation_id: facts.operation_id,
        mcp_operation_record_id: operation.id,
        kind: kind
      )
    else
      {:error, reason} -> Multi.error(Multi.new(), :mcp_execution_preflight, reason)
    end
  end

  # An older release number is refused rather than redirected: a model that
  # asked for slug@2 must be told 3 is live, not silently handed 3's content.
  defp fetch_runbook_for_mcp_execution(%{runbook_ref: runbook_ref}, :published, subject) do
    with {:ok, {slug, version}} <- parse_runbook_ref(runbook_ref),
         {:ok, runbook} <- fetch_live_runbook_by_slug(slug, subject),
         true <- runbook.live_version == version do
      {:ok, runbook}
    else
      false -> {:error, :not_live}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_runbook_for_mcp_execution(facts, :draft_test, subject) do
    queryable =
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_slug(facts.slug)
      |> Runbook.Query.has_draft()
      |> Runbook.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    with {:ok, runbook} <- Repo.fetch(queryable, Runbook.Query),
         true <- Definition.digest(runbook.draft_definition) == facts.definition_sha256 do
      {:ok, runbook}
    else
      false -> {:error, :draft_changed}
      {:error, :not_found} -> {:error, :draft_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_runbook_ref(value) when is_binary(value) do
    case Regex.run(@runbook_ref, value) do
      [_ref, slug, version] -> {:ok, {slug, String.to_integer(version)}}
      _no_match -> {:error, :invalid_runbook_ref}
    end
  end

  defp parse_runbook_ref(_value), do: {:error, :invalid_runbook_ref}

  defp settle_mcp_execution(changes, execution_id, %Subject{} = subject) do
    reservation = changes.mcp_operation
    created_execution = Map.get(changes, {:runbook_execution, execution_id})

    _ =
      case {reservation.fresh?, created_execution} do
        {true, %RunbookExecution{status: :active}} -> Scheduler.advance_execution(execution_id)
        _ -> :ok
      end

    case fetch_execution_by_id(execution_id, subject) do
      {:ok, execution} ->
        {:ok, if(reservation.fresh?, do: :created, else: :replay), execution}

      {:error, :not_found} ->
        {:error, :operation_incomplete}

      other ->
        other
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

  @doc """
  Casts one browser form's raw input strings against a canonical definition.

  Pure — it reads no rows and needs no `%Subject{}`; the returned typed values
  are exactly what `dispatch_runbook/4` and `resolve_plan/4` compile. Returns
  `{:ok, %{values: typed_values, form_values: form_values}}` or
  `{:error, %{issues: issues, field_errors: %{input_id => message},
  form_values: form_values}}`.
  """
  def cast_form_inputs(definition, form_input),
    do: Compiler.cast_form_inputs(definition, form_input)

  @doc "Returns a fresh server-side seed for one stable preflight and dispatch pair."
  def new_target_selection_seed, do: Crypto.random_secret()

  @doc """
  The structured editor's current authoring projection: the target runners a
  step may select, and the trusted catalog those runners can execute.

  Requires `view_runbooks`, plus the fleet and catalog gates the domain reads
  apply. Returns `{:ok, %EditorProjection{}}` or
  `{:error, :unauthorized | :not_found | :candidate_catalog_too_large}`.
  """
  @spec editor_projection(Subject.t()) ::
          {:ok, EditorProjection.t()}
          | {:error, :unauthorized | :not_found | :candidate_catalog_too_large}
  def editor_projection(%Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runbooks_permission()
           ),
         {:ok, runners} <-
           Runners.list_all_runners_for_account(subject, preload: [:online?]),
         available = Runners.available_runbook_targets(runners),
         {:ok, catalog} <-
           Catalog.build_editor_projection(Enum.map(available, & &1.runner), subject) do
      {:ok, %EditorProjection{targets: Enum.map(available, &editor_target/1), catalog: catalog}}
    end
  end

  defp editor_target(target) do
    %{id: target.id, runner_ref: target.runner_ref, name: target.name, group: target.group}
  end

  @doc """
  Resolves one editor step's saved target refs and selection into the runners it
  currently covers.

  `random_one` must name exactly one group, and every ref must resolve — the
  whole possible group is the target set, because the sampled member is only
  chosen at dispatch. Returns `{:ok, [target]} | {:error, :unknown_target}`.
  """
  @spec editor_target_runners(EditorProjection.t(), [String.t()], String.t()) ::
          {:ok, [EditorProjection.target()]} | {:error, :unknown_target}
  def editor_target_runners(projection, refs, selection)

  def editor_target_runners(%EditorProjection{}, [], _selection),
    do: {:error, :unknown_target}

  def editor_target_runners(%EditorProjection{} = projection, refs, "all") when is_list(refs),
    do: Runners.select_runbook_target_runners(refs, projection.targets)

  def editor_target_runners(
        %EditorProjection{} = projection,
        ["group:" <> _group = ref],
        "random_one"
      ),
      do: Runners.select_runbook_target_runners([ref], projection.targets)

  def editor_target_runners(%EditorProjection{}, _refs, _selection),
    do: {:error, :unknown_target}

  @doc """
  The actions the runners covered by one editor step's targets can execute
  under one complete common action contract.

  Every covered runner must advertise the action's pack; a covered runner whose
  deployment currently holds no trusted version narrows the executable set
  instead of hiding the action. Returns `[]` while the targets do not resolve —
  an unresolved scope cannot narrow behavior, so the editor offers nothing
  rather than guessing.
  """
  @spec editor_actions(EditorProjection.t(), [String.t()], String.t()) :: [
          EditorProjection.action()
        ]
  def editor_actions(%EditorProjection{} = projection, refs, selection) do
    case editor_target_runners(projection, refs, selection) do
      {:ok, targets} -> Catalog.common_actions(projection.catalog, Enum.map(targets, & &1.id))
      {:error, :unknown_target} -> []
    end
  end

  @doc """
  One eligible editor action for a step's current targets. Returns
  `{:ok, action} | {:error, :not_found}`; a stale, untrusted, or contract-
  incompatible choice is never found, so it contributes no risk or arguments.
  """
  @spec editor_action(EditorProjection.t(), [String.t()], String.t(), String.t(), String.t()) ::
          {:ok, EditorProjection.action()} | {:error, :not_found}
  def editor_action(%EditorProjection{} = projection, refs, selection, pack_id, action_id) do
    projection
    |> editor_actions(refs, selection)
    |> Enum.find(&(&1.pack_id == pack_id and &1.action_id == action_id))
    |> case do
      nil -> {:error, :not_found}
      action -> {:ok, action}
    end
  end

  @doc "Validates one unsaved definition through the context-owned strict contract."
  def validate_definition(definition, %Subject{} = subject) do
    with :ok <-
           Auth.Authorizer.ensure_has_permissions(
             subject,
             Authorizer.view_runbooks_permission()
           ) do
      validate_definition(definition)
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
        |> RunbookExecution.Query.ordered_by_recent()
        |> RunbookExecution.Query.limit_to(limit)
        |> RunbookExecution.Query.with_attribution()
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
        |> RunbookExecution.Query.ordered_by_recent()
        |> RunbookExecution.Query.limit_to(limit)
        |> RunbookExecution.Query.with_runbook()
        |> RunbookExecution.Query.with_attribution()
        |> Authorizer.for_subject(subject)
        |> Repo.all()

      {:ok, executions}
    end
  end

  @doc """
  Human-first attribution facts for a loaded execution, as `{who, via}`.

  `who` is the accountable human this account knows — the requesting operator,
  or an MCP execution's API-key owner — named through the initiating membership
  so directory renames stay account-local; `nil` when the attribution
  associations were not loaded (unknown is never guessed at) or no human row
  survives. `via` is the secondary channel: the API-key name (falling back to
  "LLM agent" when the key row is gone) for a key-dispatched execution, `nil`
  for a plain operator dispatch. Pure — reads what
  `RunbookExecution.Query.with_attribution/1` loads.
  """
  def execution_who_via(%RunbookExecution{} = execution),
    do: {execution_who(execution), execution_via(execution)}

  # An unloaded requester is UNKNOWN, never a fall-through to the key owner:
  # only an explicit `nil` means no operator asked for this execution, which is
  # when the key's owner IS the accountable human.
  defp execution_who(%RunbookExecution{requested_by: %Users.User{} = user} = execution),
    do: accountable_name(execution, user)

  defp execution_who(
         %RunbookExecution{
           requested_by: nil,
           api_key: %ApiKeys.ApiKey{created_by: %Users.User{} = user}
         } = execution
       ),
       do: accountable_name(execution, user)

  defp execution_who(%RunbookExecution{}), do: nil

  # The membership is the account-local naming authority, so it only names
  # anyone once it is provably THIS execution's, in THIS account, for THIS
  # person. An absent (or mismatched) membership degrades to the email, which
  # still identifies the accountable human without exposing the cross-account
  # `users.full_name` or a directory name another workspace owns; an unloaded
  # one names nobody.
  defp accountable_name(
         %RunbookExecution{initiating_membership: %Accounts.Membership{} = membership} = execution,
         %Users.User{} = user
       ) do
    if membership.id == execution.initiating_membership_id and
         membership.account_id == execution.account_id and membership.user_id == user.id do
      Accounts.member_display_name(membership, user)
    else
      user.email
    end
  end

  defp accountable_name(%RunbookExecution{initiating_membership: nil}, %Users.User{} = user),
    do: user.email

  defp accountable_name(%RunbookExecution{}, %Users.User{}), do: nil

  defp execution_via(%RunbookExecution{api_key_id: nil}), do: nil

  defp execution_via(%RunbookExecution{api_key: %ApiKeys.ApiKey{name: name}})
       when is_binary(name) and name != "",
       do: name

  defp execution_via(%RunbookExecution{}), do: "LLM agent"

  defp fetch_execution_result_row(execution_id, subject) do
    RunbookExecution.Query.by_id(execution_id)
    |> with_execution_result()
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(RunbookExecution.Query)
  end

  # Attribution rows are part of the result projection's contract: every
  # consumer attributes the execution to its accountable human via
  # `execution_who_via/1` (console header, MCP serialization keeps it cheap
  # to ignore).
  defp with_execution_result(query) do
    query
    |> RunbookExecution.Query.with_stages_and_items()
    |> RunbookExecution.Query.with_attribution()
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
  Internal frozen runner and pack targets for an execution approval notification.
  The explicit account scope prevents an adjacent-context notifier from turning an
  execution id into a cross-account lookup. The caller validates every returned
  identity and fails closed when an item is missing or malformed.
  """
  def approval_targets_for_execution(execution_id, account_id)
      when is_binary(execution_id) and is_binary(account_id) do
    execution_query =
      RunbookExecution.Query.by_account_id(account_id)
      |> RunbookExecution.Query.by_id(execution_id)

    with true <- Repo.valid_uuid?(execution_id) and Repo.valid_uuid?(account_id),
         %RunbookExecution{} <- Repo.peek(execution_query) do
      targets =
        ExecutionItem.Query.by_execution_id(execution_id)
        |> ExecutionItem.Query.select_approval_targets()
        |> Repo.all()

      {:ok, targets}
    else
      _ -> {:error, :not_found}
    end
  end

  def approval_targets_for_execution(_execution_id, _account_id), do: {:error, :not_found}

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

  @doc "Whether `subject` may author runbooks — create, save, publish, discard (operator+)."
  def subject_can_author_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.author_runbooks_permission())

  @doc "Whether `subject` may delete a runbook (admin+)."
  def subject_can_manage_runbooks?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Authorizer.manage_runbooks_permission())

  @doc "Whether `subject` may cancel a visible runbook execution."
  def subject_can_cancel_execution?(%Subject{} = subject),
    do: Auth.Authorizer.has_permission?(subject, Emisar.Runs.Authorizer.cancel_run_permission())

  defp ensure_live(%Runbook{live_version: nil}), do: {:error, :not_live}
  defp ensure_live(%Runbook{}), do: :ok

  defp ensure_membership(%Subject{membership_id: id}) when is_binary(id), do: :ok
  defp ensure_membership(_), do: {:error, :membership_required}

  # The reason is copied verbatim onto the approval request an approver reads
  # before releasing the whole execution, and into the audit trail and its
  # exports. A model composes it from runner output this product tells it to
  # distrust, so a bidi override there reverses the rendered line — the same
  # threat `ActionRun.Changeset.create/1` rejects for a direct run's `reason`.
  # Reject, don't strip: the caller can retry with clean text.
  defp ensure_reason(reason) when is_binary(reason) do
    cond do
      String.trim(reason) == "" -> {:error, :reason_required}
      SafeText.unsafe_multiline?(reason) -> {:error, :reason_unsafe_text}
      true -> :ok
    end
  end

  defp fetch_runbook_by_slug(slug, %Subject{} = subject) when is_binary(slug) do
    Runbook.Query.not_deleted()
    |> Runbook.Query.by_slug(slug)
    |> Authorizer.for_subject(subject)
    |> Repo.fetch(Runbook.Query)
  end

  defp fetch_locked_runbook(id, %Subject{} = subject, repo) do
    queryable =
      Runbook.Query.not_deleted()
      |> Runbook.Query.by_id(id)
      |> Runbook.Query.lock_for_update()
      |> Authorizer.for_subject(subject)

    repo.fetch(queryable, Runbook.Query)
  end

  # What the runbook currently RUNS, falling back to the draft while nothing has
  # been published — the definition a list row reports risk over and `expand/1`
  # walks.
  defp current_definition(%Runbook{definition: nil} = runbook), do: runbook.draft_definition
  defp current_definition(%Runbook{} = runbook), do: runbook.definition

  # What an editing surface last read, and therefore what its next save's base
  # digest is taken over: the unpublished change when there is one, else the
  # live release.
  defp editing_digest(%Runbook{draft_definition: nil} = runbook),
    do: Definition.digest(runbook.definition)

  defp editing_digest(%Runbook{} = runbook), do: Definition.digest(runbook.draft_definition)

  defp dispatched_definition(%Runbook{} = runbook, :published), do: runbook.definition
  defp dispatched_definition(%Runbook{} = runbook, :draft_test), do: runbook.draft_definition

  defp expand_definition(%{"stages" => stages}) when is_list(stages),
    do: Enum.flat_map(stages, &(&1["steps"] || []))

  defp expand_definition(_definition), do: []

  # -- Authoring scope --------------------------------------------------

  # The definition the author is WRITING, read back off the cast changeset so
  # the guard and the write cannot disagree. An invalid changeset passes: its
  # own field errors are the honest answer, and nothing is written either way.
  defp ensure_authored_changeset_in_access(%Ecto.Changeset{valid?: false}, %Subject{}), do: :ok

  defp ensure_authored_changeset_in_access(%Ecto.Changeset{} = changeset, %Subject{} = subject) do
    definition = Ecto.Changeset.get_field(changeset, :draft_definition)
    ensure_definition_in_author_access(definition, subject)
  end

  # The MCP writes reserve their operation before the definition is judged, so
  # the author-scope gate runs inside that same transaction: a refusal rolls the
  # reservation back exactly as a rejected definition does, leaving the model
  # free to retry the operation with an in-scope step.
  defp authored_definition({:ok, definition}, %Subject{} = subject) do
    with :ok <- ensure_definition_in_author_access(definition, subject), do: {:ok, definition}
  end

  defp authored_definition({:error, reason}, %Subject{}), do: {:error, reason}

  # Every step a member authors must name only runners, groups and packs that
  # member can already reach. Without this, a narrowly-scoped author could write
  # a step reaching a runner or pack they may not touch and hand the result to
  # someone who may — laundering privilege through a shared document. A draft is
  # deliberately allowed to be INCOMPLETE: a step with no pack or no targets yet
  # reaches nothing, so it passes; only a NAMED out-of-scope ref or pack fails.
  defp ensure_definition_in_author_access(definition, %Subject{} = subject) do
    steps = expand_definition(definition)
    refs = steps |> Enum.flat_map(&step_target_refs/1) |> Enum.uniq()

    with :ok <- ensure_step_packs_in_access(steps, subject),
         {:ok, outside} <- Runners.refs_outside_runner_access(refs, subject) do
      if outside == [], do: :ok, else: {:error, :target_out_of_scope}
    end
  end

  defp ensure_step_packs_in_access(steps, %Subject{} = subject) do
    access = Accounts.runner_access_for_subject(subject)
    pack_ids = Enum.flat_map(steps, &step_pack_id/1)

    if Enum.all?(pack_ids, &Accounts.RunnerAccess.pack_in_scope?(&1, access)),
      do: :ok,
      else: {:error, :pack_out_of_scope}
  end

  defp step_pack_id(%{"pack" => %{"id" => pack_id}}) when is_binary(pack_id) and pack_id != "",
    do: [pack_id]

  defp step_pack_id(_step), do: []

  defp step_target_refs(%{"targets" => %{"refs" => refs}}) when is_list(refs),
    do: Enum.filter(refs, &is_binary/1)

  defp step_target_refs(_step), do: []
end

defmodule Emisar.Repo do
  use Ecto.Repo,
    otp_app: :emisar,
    adapter: Ecto.Adapters.Postgres

  alias Emisar.Repo.{Filter, Paginator, Preloader}
  require Ecto.Query

  @doc "True iff `binary` is a string-encoded UUID."
  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_), do: false

  @doc """
  A fresh primary-key id, matching what schemas autogenerate on insert
  (UUIDv7, monotonic). Use it to fill `:id` for `insert_all` rows, which —
  unlike `insert/2` — does not run the schema's autogenerate.
  """
  def generate_id, do: Ecto.UUID.autogenerate(version: 7, precision: :monotonic)

  @doc """
  nil-or-struct fetcher for internal helpers where `nil` is a
  meaningful "no row" result (e.g. default-deny policy lookup, opaque
  prefix-keyed credential lookups). The query must already be built
  via a Query module — never pass a raw schema atom here.
  """
  @spec peek(Ecto.Queryable.t()) :: Ecto.Schema.t() | nil
  def peek(queryable), do: __MODULE__.one(queryable)

  @doc """
  Single-result fetcher with filter support. Returns `{:ok, schema}`
  or `{:error, :not_found}`. Raises if more than one row matches.

  Options:

    * `:filter` — `Emisar.Repo.Filter.filters()` to apply
    * `:preload` — Ecto preload list, applied after the fetch
  """
  @spec fetch(Ecto.Queryable.t(), module(), keyword()) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, {:unknown_filter, keyword()}}
          | {:error, {:invalid_type, keyword()}}
          | {:error, {:invalid_value, keyword()}}
  def fetch(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter),
         schema when not is_nil(schema) <- __MODULE__.one(queryable, opts) do
      {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
      {:ok, __MODULE__.preload(schema, ecto_preloads)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Same as `fetch/3` but raises `Ecto.NoResultsError` when the row is
  missing. Use for invariants the caller is certain about (`*!`
  helpers): the surrounding code already proved presence via a
  foreign-key relationship or a prior fetch.
  """
  @spec fetch!(Ecto.Queryable.t(), module(), keyword()) :: Ecto.Schema.t()
  def fetch!(queryable, query_module, opts \\ []) do
    case fetch(queryable, query_module, opts) do
      {:ok, schema} -> schema
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: queryable
      {:error, reason} -> raise "Emisar.Repo.fetch!/2 failed: #{inspect(reason)}"
    end
  end

  @type after_commit :: (term() -> :ok) | (term(), Ecto.Changeset.t() -> :ok)
  @type changeset_fun :: (term() -> Ecto.Changeset.t() | term())
  @type audit_fun ::
          (term() -> Ecto.Changeset.t() | nil)
          | (term(), Ecto.Changeset.t() -> Ecto.Changeset.t() | nil)

  @doc """
  Locks the row matched by `queryable` with `FOR NO KEY UPDATE`, runs
  the supplied changeset function inside a transaction, then invokes
  any `after_commit` callbacks once committed. This is the standard
  mutation pattern: read-locked fetch → changeset → optional audit
  insert (in-transaction) → broadcast (after commit).

  Options:

    * `:with` — `(schema -> changeset | abort_reason)` (required).
      Runs inside the transaction on the locked row, so domain guards
      that must judge the row's CURRENT state belong here: returning
      anything other than a changeset aborts and surfaces as
      `{:error, that_value}`. An invariant query the guard needs (a
      locked owner re-count) is a plain repo call — it joins this
      transaction.
    * `:audit` — when set, the returned audit changeset is inserted in
      the SAME transaction as the update, so the audit row is atomic
      with the parent mutation. Receives `(updated)` or
      `(updated, changeset)` — `changeset.data` is the locked
      pre-update row, for audit payloads that record before-state.
      Return `nil` to skip audit for this call. The inserted row is
      broadcast to the account's audit topic once committed, same as
      `commit_multi/2`.
    * `:after_commit` — callback or list of callbacks; each receives
      `(schema)` or `(schema, changeset)` and must return `:ok`.
      Fires only after the DB transaction commits — use for broadcasts
      and other side effects that should NOT happen on rollback.
    * `:filter` — `Emisar.Repo.Filter.filters()` to constrain the lookup
    * `:preload` — Ecto preloads applied after the update
  """
  @spec fetch_and_update(Ecto.Queryable.t(), module(), keyword()) ::
          {:ok, Ecto.Schema.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def fetch_and_update(queryable, query_module, opts) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {after_commit, opts} = Keyword.pop(opts, :after_commit, [])
    {audit_fun, opts} = Keyword.pop(opts, :audit)
    {changeset_fun, repo_opts} = Keyword.pop!(opts, :with)

    # Inside an already-open transaction this call JOINS it, so its
    # "after commit" would fire before the OUTER commit — side effects
    # would escape a later rollback. Hoist them to the outer
    # commit_multi(after_commit: …) instead.
    if after_commit != [] and in_transaction?() do
      raise ArgumentError,
            "fetch_and_update :after_commit inside an open transaction fires before " <>
              "the outer commit — pass the side effects to the outer " <>
              "Repo.commit_multi(after_commit: …) instead"
    end

    queryable = Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      fn -> locked_update(queryable, changeset_fun, audit_fun, repo_opts) end
      |> transaction(repo_opts)
      |> case do
        {:ok, {{:ok, schema}, changeset, audit_event}} ->
          :ok = fan_out_audit_events(%{audit: audit_event})
          :ok = execute_after_commit(schema, changeset, after_commit)
          {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
          {:ok, __MODULE__.preload(schema, ecto_preloads)}

        {:ok, {{:error, reason}, _changeset}} ->
          {:error, reason}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The fetch_and_update/3 transaction body: load the locked row, run the
  # caller's :with on it, apply the update, insert the audit row in the
  # same transaction. The tuple shapes feed the response-shaping case in
  # fetch_and_update/3.
  defp locked_update(queryable, changeset_fun, audit_fun, repo_opts) do
    if schema = __MODULE__.one(queryable, repo_opts) do
      case changeset_fun.(schema) do
        %Ecto.Changeset{} = changeset ->
          case update(changeset, mode: :savepoint) do
            {:ok, updated} = ok ->
              case maybe_insert_audit(audit_fun, updated, changeset) do
                {:ok, audit_event} -> {ok, changeset, audit_event}
                {:error, reason} -> rollback({:audit_failed, reason})
              end

            err ->
              {err, changeset}
          end

        reason ->
          {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp maybe_insert_audit(nil, _schema, _changeset), do: {:ok, nil}

  defp maybe_insert_audit(audit_fun, schema, changeset) do
    built =
      cond do
        is_function(audit_fun, 1) -> audit_fun.(schema)
        is_function(audit_fun, 2) -> audit_fun.(schema, changeset)
      end

    case built do
      nil -> {:ok, nil}
      %Ecto.Changeset{} = audit_changeset -> insert(audit_changeset, mode: :savepoint)
    end
  end

  defp execute_after_commit(schema, changeset, after_commit) do
    after_commit
    |> List.wrap()
    |> Enum.each(fn
      callback when is_function(callback, 1) -> :ok = callback.(schema)
      callback when is_function(callback, 2) -> :ok = callback.(schema, changeset)
    end)
  end

  @doc """
  Runs `multi` inside a transaction and, on success, fires any
  `:after_commit` callbacks with the multi's `changes` map. This is
  the canonical way to commit a parent mutation together with its
  audit row(s) atomically while keeping broadcasts as a post-commit
  side effect (only fire if the DB actually committed).

  Returns `{:ok, changes}` on success, `{:error, reason}` if any
  `Multi.run/3` step returned `{:error, reason}`, or `{:error,
  changeset}` if a changeset step failed — callers can dispatch on
  the failure shape.

  Example:

      Multi.new()
      |> Multi.update(:policy, Policy.Changeset.update(policy, attrs))
      |> Multi.insert(:audit, fn %{policy: p} ->
        Audit.changeset(p.account_id, "policy.updated",
          actor_id: subject.actor.id, subject_id: p.id, payload: %{...})
      end)
      |> Repo.commit_multi(after_commit: fn %{policy: p} ->
        broadcast_policy_change(p)
      end)

  Options:

    * `:after_commit` — callback `(changes_map -> :ok)` or a list of
      them, fired once the transaction commits
    * other options forwarded to `transaction/2`
  """
  @spec commit_multi(Ecto.Multi.t(), keyword()) ::
          {:ok, map()}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def commit_multi(multi, opts \\ []) do
    {after_commit, repo_opts} = Keyword.pop(opts, :after_commit, [])

    # Inside an already-open transaction this multi JOINS it, so its
    # "after commit" fires when the INNER transaction returns — before the
    # OUTER commit — letting side effects (broadcasts, email) escape a later
    # outer rollback. Compose the steps into the outer Multi and hoist the
    # side effects to the outer commit_multi(after_commit: …) instead
    # (mirrors the fetch_and_update/3 guard above).
    if after_commit != [] and in_transaction?() do
      raise ArgumentError,
            "commit_multi :after_commit inside an open transaction fires before " <>
              "the outer commit — compose the steps into the outer Multi and pass " <>
              "the side effects to its Repo.commit_multi(after_commit: …) instead"
    end

    case transaction(multi, repo_opts) do
      {:ok, changes} ->
        :ok = fan_out_audit_events(changes)
        :ok = execute_changes_after_commit(changes, after_commit)
        {:ok, changes}

      {:error, _failed_op, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _failed_op, reason, _changes} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_changes_after_commit(changes, after_commit) do
    after_commit
    |> List.wrap()
    |> Enum.each(fn callback when is_function(callback, 1) -> :ok = callback.(changes) end)
  end

  # Every Multi that includes an audit-event step (via `Audit.changeset`
  # or `Audit.Multi.log_for_user`) auto-broadcasts each row to the account-wide
  # `:audit` topic once the transaction commits. AuditLive subscribes
  # there and reloads, so the live audit log stays current without each
  # context having to remember to broadcast.
  #
  # Tolerates the case where Audit isn't compiled (test-only) by routing
  # through `Code.ensure_loaded?` — keeps the data app's startup honest.
  defp fan_out_audit_events(changes) when is_map(changes) do
    if Code.ensure_loaded?(Emisar.Audit) and Code.ensure_loaded?(Emisar.Audit.Event) do
      Enum.each(changes, fn
        {_step, %Emisar.Audit.Event{} = event} -> Emisar.Audit.broadcast_event(event)
        _ -> :ok
      end)
    end

    :ok
  end

  defp fan_out_audit_events(_), do: :ok

  @doc """
  Paginated list with cursor metadata. Options:

    * `:filter` — filter list applied via `Emisar.Repo.Filter`
    * `:order_by` — extra cursor fields prepended to the query module's
    * `:preload` — Ecto preload list
    * `:page` — `[cursor: ..., limit: ...]` (limit clamped to [1, 100])

  Returns `{:ok, [schema], %Paginator.Metadata{}}` so the LiveTable
  can render Prev/Next cursors directly.
  """
  @spec list(Ecto.Queryable.t(), module(), keyword()) ::
          {:ok, [Ecto.Schema.t()], Paginator.Metadata.t()}
          | {:error, :invalid_cursor}
          | {:error, term()}
  def list(queryable, query_module, opts \\ []) do
    {preload, opts} = Keyword.pop(opts, :preload, [])
    {filter, opts} = Keyword.pop(opts, :filter, [])
    {order_by, opts} = Keyword.pop(opts, :order_by, [])
    {paginator_opts, opts} = Keyword.pop(opts, :page, [])

    with {:ok, paginator_opts} <- Paginator.init(query_module, order_by, paginator_opts),
         {:ok, queryable} <- Filter.filter(queryable, query_module, filter),
         keyset_query = Paginator.query(queryable, paginator_opts),
         {:ok, rows} <- run_keyset_query(keyset_query, opts) do
      count = __MODULE__.aggregate(queryable, :count, :id)
      {results, metadata} = Paginator.metadata(rows, paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = __MODULE__.preload(results, ecto_preloads)
      {:ok, results, %{metadata | count: count}}
    end
  end

  # A structurally-valid `:safe`-decoded cursor can still carry a value whose
  # type doesn't match its keyset column (a string where the column is a
  # UUID/integer). That survives `decode_cursor` and only fails when the keyset
  # WHERE is bound + executed — Ecto raises `Ecto.Query.CastError`, or Postgrex
  # raises `DBConnection.EncodeError` when the schema has no type to pre-cast
  # against. Map both to the same clean `:invalid_cursor` the malformed-cursor
  # path returns, so a crafted `?after=` is a 4xx-able outcome, not a self-500.
  # Narrow on purpose: a genuine query/connection fault still raises.
  defp run_keyset_query(keyset_query, opts) do
    {:ok, __MODULE__.all(keyset_query, opts)}
  rescue
    Ecto.Query.CastError -> {:error, :invalid_cursor}
    DBConnection.EncodeError -> {:error, :invalid_cursor}
  end
end

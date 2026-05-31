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
  @type changeset_fun :: (term() -> Ecto.Changeset.t())

  @doc """
  Locks the row matched by `queryable` with `FOR NO KEY UPDATE`, runs
  the supplied changeset function inside a transaction, then invokes
  any `after_commit` callbacks once committed. This is the standard
  mutation pattern: read-locked fetch → changeset → audit/broadcast
  as a post-commit side effect.

  Options:

    * `:with` — `(schema -> changeset)` (required)
    * `:after_commit` — callback or list of callbacks; each receives
      `(schema)` or `(schema, changeset)` and must return `:ok`
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
    {changeset_fun, repo_opts} = Keyword.pop!(opts, :with)

    queryable = Ecto.Query.lock(queryable, "FOR NO KEY UPDATE")

    with {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      fn ->
        if schema = __MODULE__.one(queryable, repo_opts) do
          case changeset_fun.(schema) do
            %Ecto.Changeset{} = cs ->
              {update(cs, mode: :savepoint), cs}

            reason ->
              {:error, reason}
          end
        else
          {:error, :not_found}
        end
      end
      |> transaction(repo_opts)
      |> case do
        {:ok, {{:ok, schema}, cs}} ->
          :ok = execute_after_commit(schema, cs, after_commit)
          {schema, ecto_preloads} = Preloader.preload(schema, preload, query_module)
          {:ok, __MODULE__.preload(schema, ecto_preloads)}

        {:ok, {{:error, reason}, _cs}} ->
          {:error, reason}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp execute_after_commit(schema, changeset, after_commit) do
    after_commit
    |> List.wrap()
    |> Enum.each(fn
      cb when is_function(cb, 1) -> :ok = cb.(schema)
      cb when is_function(cb, 2) -> :ok = cb.(schema, changeset)
    end)
  end

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
         {:ok, queryable} <- Filter.filter(queryable, query_module, filter) do
      count = __MODULE__.aggregate(queryable, :count, :id)

      {results, metadata} =
        queryable
        |> Paginator.query(paginator_opts)
        |> __MODULE__.all(opts)
        |> Paginator.metadata(paginator_opts)

      {results, ecto_preloads} = Preloader.preload(results, preload, query_module)
      results = __MODULE__.preload(results, ecto_preloads)
      {:ok, results, %{metadata | count: count}}
    end
  end
end

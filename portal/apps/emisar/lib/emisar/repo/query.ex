defmodule Emisar.Repo.Query do
  @moduledoc """
  Behaviour and helpers for per-entity Query modules. Every entity has
  its own `<Entity>.Query` that starts every chain with `from(x in
  Schema, as: :x)` and offers composable `by_<field>/2` helpers.

  Optional callbacks consumed by `Emisar.Repo.list/3`:

    * `cursor_fields/0` — fields for keyset pagination (required for
      `Repo.list/3` to work).
    * `filters/0` — `Emisar.Repo.Filter.t()` definitions surfaced by
      `LiveTable` and applied via `Repo.list/3`'s `:filter` option.
  """
  alias Emisar.Repo.Filter
  import Ecto.Query

  @type direction :: :after | :before
  @type cursor_fields :: [{binding :: atom(), :asc | :desc, field :: atom()}]

  @type preload_fun ::
          ([Ecto.Schema.t()] -> [Ecto.Schema.t()])
          | Ecto.Queryable.t()
          | (-> Ecto.Queryable.t())
  @type preload_funs :: [{atom(), preload_fun()} | {atom(), {preload_fun(), preload_funs()}}]

  @callback cursor_fields() :: cursor_fields()
  @callback filters() :: [Filter.t()]
  @callback preloads() :: preload_funs()

  @optional_callbacks [cursor_fields: 0, filters: 0, preloads: 0]

  # -- Callback helpers ------------------------------------------------

  def fetch_cursor_fields!(query_module), do: query_module.cursor_fields()

  def get_filters(query_module) do
    _ = Code.ensure_loaded(query_module)

    if Kernel.function_exported?(query_module, :filters, 0) do
      query_module.filters()
    else
      []
    end
  end

  def get_preloads_funs(query_module) do
    _ = Code.ensure_loaded(query_module)

    if Kernel.function_exported?(query_module, :preloads, 0) do
      query_module.preloads()
    else
      []
    end
  end

  # -- Filter helpers --------------------------------------------------

  @doc """
  Helper for the `t:Filter.fun/0` shape — apply a filter callback
  return value to the queryable as a `where` clause.
  """
  def apply_filter({%Ecto.Query{} = queryable, %Ecto.Query.DynamicExpr{} = dynamic}) do
    where(queryable, ^dynamic)
  end

  @doc """
  Chains multiple filter callbacks against the same queryable, ANDing
  the returned dynamic expressions together.
  """
  def append_filter(queryable, fun) when is_function(fun, 1) do
    {queryable, dynamic} = fun.(queryable)
    apply_filter({queryable, dynamic})
  end
end

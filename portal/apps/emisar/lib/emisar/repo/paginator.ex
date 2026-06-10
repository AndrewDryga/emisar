defmodule Emisar.Repo.Paginator do
  @moduledoc """
  Keyset (cursor) pagination — fast and stable under concurrent
  inserts/deletes. The cursor encodes the last row's `cursor_fields`
  values, opaque to callers.
  """
  import Ecto.Query
  alias Emisar.Repo.Query

  @default_limit 35
  @max_limit 100

  defmodule Metadata do
    @type t :: %__MODULE__{
            previous_page_cursor: binary() | nil,
            next_page_cursor: binary() | nil,
            limit: non_neg_integer(),
            count: non_neg_integer() | nil
          }

    defstruct previous_page_cursor: nil,
              next_page_cursor: nil,
              limit: nil,
              count: nil
  end

  def init(query_module, order_by, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    limit = max(min(limit, @max_limit), 1)

    cursor_fields =
      (order_by ++ Query.fetch_cursor_fields!(query_module))
      |> Enum.reduce([], fn
        {binding, _new_order, field}, [{binding, _prev_order, field} | _] = acc -> acc
        {binding, order, field}, acc -> [{binding, order, field}] ++ acc
      end)
      |> Enum.reverse()

    if encoded = Keyword.get(opts, :cursor) do
      with {:ok, {direction, values}} <- decode_cursor(encoded) do
        {:ok,
         %{
           query_module: query_module,
           cursor_fields: cursor_fields,
           limit: limit,
           direction: direction,
           values: values
         }}
      end
    else
      {:ok, %{query_module: query_module, cursor_fields: cursor_fields, limit: limit}}
    end
  end

  def query(queryable, paginator_opts) do
    queryable
    |> order_by_cursor_fields(paginator_opts)
    |> maybe_query_page(paginator_opts)
    |> limit_page_size(paginator_opts)
  end

  defp order_by_cursor_fields(queryable, %{cursor_fields: cursor_fields, direction: :before}) do
    queryable
    |> default_order_by_cursor_fields(cursor_fields)
    |> Ecto.Query.reverse_order()
  end

  defp order_by_cursor_fields(queryable, %{cursor_fields: cursor_fields}),
    do: default_order_by_cursor_fields(queryable, cursor_fields)

  defp default_order_by_cursor_fields(queryable, cursor_fields) do
    Enum.reduce(cursor_fields, queryable, fn {binding, order, field}, q ->
      order_by(q, [{^binding, b}], [{^order, field(b, ^field)}])
    end)
  end

  defp maybe_query_page(queryable, %{
         direction: direction,
         cursor_fields: cursor_fields,
         values: values
       }) do
    dynamic =
      cursor_fields
      |> Enum.zip(values)
      |> Enum.reverse()
      |> Enum.reduce(nil, fn {field, value}, dynamic ->
        append_by_cursor_dynamic(dynamic, direction, field, value)
      end)

    where(queryable, ^dynamic)
  end

  defp maybe_query_page(queryable, _opts), do: queryable

  # ASC
  defp append_by_cursor_dynamic(nil, :before, {binding, :asc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) < ^value)

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :asc, field}, value),
    do:
      dynamic(
        [{^binding, b}],
        field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic)
      )

  defp append_by_cursor_dynamic(nil, :after, {binding, :asc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) > ^value)

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :asc, field}, value),
    do:
      dynamic(
        [{^binding, b}],
        field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
      )

  # DESC
  defp append_by_cursor_dynamic(nil, :before, {binding, :desc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) > ^value)

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :desc, field}, value),
    do:
      dynamic(
        [{^binding, b}],
        field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
      )

  defp append_by_cursor_dynamic(nil, :after, {binding, :desc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) < ^value)

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :desc, field}, value),
    do:
      dynamic(
        [{^binding, b}],
        field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic)
      )

  # Load limit+1 to know whether there's another page.
  defp limit_page_size(queryable, %{limit: limit}), do: Ecto.Query.limit(queryable, ^(limit + 1))

  def empty_metadata, do: %Metadata{limit: @default_limit}

  def metadata([], %{limit: limit}), do: {[], %Metadata{limit: limit}}

  def metadata(results, %{direction: :before, cursor_fields: cf, limit: limit})
      when length(results) > limit do
    results = results |> List.delete_at(-1) |> Enum.reverse()

    {results,
     %Metadata{
       previous_page_cursor: encode_cursor(:before, cf, List.first(results)),
       next_page_cursor: encode_cursor(:after, cf, List.last(results)),
       limit: limit
     }}
  end

  def metadata(results, %{direction: :before, cursor_fields: cf, limit: limit}) do
    results = Enum.reverse(results)

    {results,
     %Metadata{
       previous_page_cursor: nil,
       next_page_cursor: encode_cursor(:after, cf, List.last(results)),
       limit: limit
     }}
  end

  def metadata(results, %{direction: :after, cursor_fields: cf, limit: limit})
      when length(results) > limit do
    results = List.delete_at(results, -1)

    {results,
     %Metadata{
       previous_page_cursor: encode_cursor(:before, cf, List.first(results)),
       next_page_cursor: encode_cursor(:after, cf, List.last(results)),
       limit: limit
     }}
  end

  def metadata(results, %{direction: :after, cursor_fields: cf, limit: limit}) do
    {results,
     %Metadata{
       previous_page_cursor: encode_cursor(:before, cf, List.first(results)),
       next_page_cursor: nil,
       limit: limit
     }}
  end

  def metadata(results, %{cursor_fields: cf, limit: limit}) when length(results) > limit do
    results = List.delete_at(results, -1)

    {results,
     %Metadata{
       previous_page_cursor: nil,
       next_page_cursor: encode_cursor(:after, cf, List.last(results)),
       limit: limit
     }}
  end

  def metadata(results, %{limit: limit}) do
    {results, %Metadata{previous_page_cursor: nil, next_page_cursor: nil, limit: limit}}
  end

  @doc false
  def encode_cursor(direction, cursor_fields, schema) do
    {direction, compress_cursor(schema, cursor_fields)}
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp compress_cursor(schema, cursor_fields) do
    Enum.map(cursor_fields, fn {_binding, _order, field} ->
      case Map.fetch!(schema, field) do
        %DateTime{} = dt -> {DateTime, DateTime.to_unix(dt, :nanosecond)}
        %NaiveDateTime{} = ndt -> {NaiveDateTime, NaiveDateTime.to_iso8601(ndt)}
        %Date{} = date -> {Date, Date.to_iso8601(date)}
        %Time{} = time -> {Time, Time.to_iso8601(time)}
        nil -> nil
        other -> {:t, other}
      end
    end)
  end

  defp decode_cursor(encoded) do
    # `:safe` rejects funs, pids, ports, references and any unknown
    # atoms — leaves the integer/tuple/binary leaves we serialized in.
    with {:ok, etf} <- Base.url_decode64(encoded, padding: false),
         {direction, values} <- :erlang.binary_to_term(etf, [:safe]),
         values = decompress_cursor(values),
         false <- Enum.any?(values, &is_nil/1) do
      {:ok, {direction, values}}
    else
      _ -> {:error, :invalid_cursor}
    end
  rescue
    _ -> {:error, :invalid_cursor}
  end

  defp decompress_cursor(cursor_fields) do
    Enum.map(cursor_fields, fn
      nil -> nil
      {:t, term} -> term
      {DateTime, ns} -> DateTime.from_unix!(ns, :nanosecond)
      {NaiveDateTime, iso} -> NaiveDateTime.from_iso8601!(iso)
      {Date, iso} -> Date.from_iso8601!(iso)
      {Time, iso} -> Time.from_iso8601!(iso)
    end)
  end
end

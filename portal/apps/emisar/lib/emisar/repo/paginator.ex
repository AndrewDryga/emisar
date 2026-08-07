defmodule Emisar.Repo.Paginator do
  @moduledoc """
  Keyset (cursor) pagination — fast and stable under concurrent
  inserts/deletes. The cursor encodes the last row's `cursor_fields`
  values as a typed JSON envelope — `["after" | "before", [[tag, value], …]]`
  — in URL-safe Base64 without padding, opaque to callers.
  """
  import Ecto.Query
  alias Emisar.Repo.Query

  @default_limit 35
  @max_limit 100

  # A cursor is the one place an operator-supplied string is turned back into
  # query values, so it never reaches a term decoder: `binary_to_term` lets a
  # crafted string allocate whatever the transport allowed, while JSON plus an
  # exact tag-per-leaf whitelist can only produce the scalars we serialized.
  # A legitimate cursor holds one boundary value per keyset field, so 8 KiB is
  # already generous; the encoded cap is that payload's padded Base64 ceiling,
  # checked first so an oversized string is rejected before any decode runs.
  @max_decoded_cursor_bytes 8192
  @max_encoded_cursor_bytes 10_924

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

    # First occurrence wins, wherever the repeat sits: a caller-prepended
    # field overrides the query module's direction for it, and no field
    # appears twice — a duplicated keyset slot would let a crafted cursor
    # carry two different boundary values for one column.
    cursor_fields =
      (order_by ++ Query.fetch_cursor_fields!(query_module))
      |> Enum.uniq_by(fn {binding, _order, field} -> {binding, field} end)

    if encoded = Keyword.get(opts, :cursor) do
      with {:ok, {direction, values}} <- decode_cursor(encoded, length(cursor_fields)) do
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
    Enum.reduce(cursor_fields, queryable, fn {binding, order, field}, queryable ->
      order_by(queryable, [{^binding, b}], [{^order, field(b, ^field)}])
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

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :asc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  defp append_by_cursor_dynamic(nil, :after, {binding, :asc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) > ^value)

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :asc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  # DESC
  defp append_by_cursor_dynamic(nil, :before, {binding, :desc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) > ^value)

  defp append_by_cursor_dynamic(dynamic, :before, {binding, :desc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) > ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  defp append_by_cursor_dynamic(nil, :after, {binding, :desc, field}, value),
    do: dynamic([{^binding, b}], field(b, ^field) < ^value)

  defp append_by_cursor_dynamic(dynamic, :after, {binding, :desc, field}, value) do
    dynamic(
      [{^binding, b}],
      field(b, ^field) < ^value or (field(b, ^field) == ^value and ^dynamic)
    )
  end

  # Load limit+1 to know whether there's another page.
  defp limit_page_size(queryable, %{limit: limit}), do: Ecto.Query.limit(queryable, ^(limit + 1))

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
  def encode_cursor(direction, cursor_fields, schema) when direction in [:after, :before] do
    values =
      Enum.map(cursor_fields, fn {_binding, _order, field} ->
        encode_value(Map.fetch!(schema, field))
      end)

    json = Jason.encode!([Atom.to_string(direction), values])
    encoded = Base.url_encode64(json, padding: false)

    if byte_size(json) > @max_decoded_cursor_bytes or
         byte_size(encoded) > @max_encoded_cursor_bytes do
      raise ArgumentError,
            "cursor of #{byte_size(json)} bytes exceeds the " <>
              "#{@max_decoded_cursor_bytes}-byte keyset cursor cap"
    end

    encoded
  end

  defp encode_value(%DateTime{} = datetime),
    do: ["datetime", DateTime.to_unix(datetime, :nanosecond)]

  defp encode_value(%NaiveDateTime{} = naive_datetime),
    do: ["naive_datetime", NaiveDateTime.to_iso8601(naive_datetime)]

  defp encode_value(%Date{} = date), do: ["date", Date.to_iso8601(date)]
  defp encode_value(%Time{} = time), do: ["time", Time.to_iso8601(time)]
  defp encode_value(value) when is_binary(value), do: ["binary", value]
  defp encode_value(value) when is_boolean(value), do: ["boolean", value]
  defp encode_value(value) when is_integer(value), do: ["integer", value]
  defp encode_value(value) when is_float(value), do: ["float", value]

  defp encode_value(_value),
    do: raise(ArgumentError, "keyset cursor value has no cursor type")

  defp decode_cursor(encoded, value_count)
       when is_binary(encoded) and byte_size(encoded) <= @max_encoded_cursor_bytes do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(json) <= @max_decoded_cursor_bytes,
         {:ok, [encoded_direction, encoded_values]} <- Jason.decode(json),
         {:ok, direction} <- decode_direction(encoded_direction),
         true <- is_list(encoded_values),
         true <- length(encoded_values) == value_count,
         {:ok, values} <- decode_values(encoded_values) do
      {:ok, {direction, values}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_encoded, _value_count), do: {:error, :invalid_cursor}

  defp decode_direction("after"), do: {:ok, :after}
  defp decode_direction("before"), do: {:ok, :before}
  defp decode_direction(_encoded_direction), do: {:error, :invalid_cursor}

  defp decode_values(encoded_values) do
    decoded =
      Enum.reduce_while(encoded_values, {:ok, []}, fn encoded_value, {:ok, values} ->
        case decode_value(encoded_value) do
          {:ok, value} -> {:cont, {:ok, [value | values]}}
          {:error, _reason} -> {:halt, {:error, :invalid_cursor}}
        end
      end)

    with {:ok, values} <- decoded, do: {:ok, Enum.reverse(values)}
  end

  defp decode_value(["binary", value]) when is_binary(value), do: {:ok, value}
  defp decode_value(["boolean", value]) when is_boolean(value), do: {:ok, value}
  defp decode_value(["integer", value]) when is_integer(value), do: {:ok, value}
  defp decode_value(["float", value]) when is_float(value), do: {:ok, value}

  defp decode_value(["datetime", value]) when is_integer(value),
    do: DateTime.from_unix(value, :nanosecond)

  defp decode_value(["naive_datetime", value]) when is_binary(value),
    do: NaiveDateTime.from_iso8601(value)

  defp decode_value(["date", value]) when is_binary(value), do: Date.from_iso8601(value)
  defp decode_value(["time", value]) when is_binary(value), do: Time.from_iso8601(value)
  defp decode_value(_encoded_value), do: {:error, :invalid_cursor}
end

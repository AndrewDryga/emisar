defmodule Emisar.Repo.Filter do
  @moduledoc """
  Declarative filter definitions for query modules. Each `<Entity>.Query`
  exposes a list of `%Filter{}` structs via the `filters/0` callback;
  `Emisar.Repo.list/3` applies them by name from the caller's `:filter`
  keyword.

  Filters also describe themselves to the UI: `name` + `type` + `values`
  is enough for `EmisarWeb.LiveTable` to render an input automatically.
  The `fun` callback carries the SQL. `advanced: true` tucks a niche filter
  behind the bar's "More filters" disclosure (it still applies — it's just
  collapsed by default, and the disclosure opens itself when it's set).
  """
  import Ecto.Query
  alias Emisar.Repo.Filter.Range
  alias Emisar.Repo.Query

  @typedoc "A list of `{name, value}` pairs applied conjunctively."
  @type filters :: [{name :: atom(), value :: term()}]

  @type numeric_type :: :integer | :number
  @type datetime_type :: :date | :time | :datetime
  @type binary_type :: :string | {:string, :email | :uuid | :websearch}
  @type range_type :: {:range, numeric_type() | datetime_type()}
  @type type ::
          :boolean
          | binary_type()
          | numeric_type()
          | datetime_type()
          | range_type()
          | {:list, type()}

  @type fun ::
          (Ecto.Queryable.t(), value :: term() ->
             {Ecto.Queryable.t(), %Ecto.Query.DynamicExpr{}})
          | (Ecto.Queryable.t() ->
               {Ecto.Queryable.t(), %Ecto.Query.DynamicExpr{}})

  @type values :: [{value :: term(), name :: String.t()}]

  @type t :: %__MODULE__{
          name: atom(),
          title: String.t() | nil,
          type: type(),
          values: values() | Range.t() | nil,
          fun: fun(),
          advanced: boolean()
        }

  defstruct name: nil, title: nil, type: nil, values: nil, fun: nil, advanced: false

  @doc """
  Apply the supplied filter list to the queryable. Returns
  `{:ok, queryable}` ready to feed back into Repo functions, or an
  error tuple identifying the bad filter.
  """
  @spec filter(Ecto.Queryable.t(), module(), filters()) ::
          {:ok, Ecto.Queryable.t()}
          | {:error, {:unknown_filter, keyword()}}
          | {:error, {:invalid_type, keyword()}}
          | {:error, {:invalid_value, keyword()}}
  def filter(queryable, query_module, filters) do
    definitions =
      for definition <- Query.get_filters(query_module), into: %{} do
        {definition.name, definition}
      end

    case build_dynamic(queryable, filters, definitions, nil) do
      {:error, reason} -> {:error, reason}
      {queryable, nil} -> {:ok, queryable}
      {queryable, dynamic} -> {:ok, where(queryable, ^dynamic)}
    end
  end

  @doc false
  def build_dynamic(queryable, _filters, [], acc), do: {queryable, acc}
  def build_dynamic(queryable, [], _definitions, acc), do: {queryable, acc}

  def build_dynamic(queryable, [{name, value} | rest], definitions, acc) do
    with {:ok, {queryable, dynamic}} <- apply_filter(definitions, name, value, queryable) do
      build_dynamic(queryable, rest, definitions, merge_dynamic(acc, dynamic))
    end
  end

  defp apply_filter(definitions, name, value, queryable) do
    with {:ok, definition} <- Map.fetch(definitions, name),
         :ok <- validate_value(definition, value) do
      {:ok, apply_filter_fun!(queryable, definition, value)}
    else
      :error ->
        {:error, {:unknown_filter, name: name}}

      {:error, {:invalid_type, metadata}} ->
        {:error, {:invalid_type, [name: name] ++ metadata}}

      {:error, {:invalid_value, metadata}} ->
        {:error, {:invalid_value, [name: name] ++ metadata}}
    end
  end

  defp apply_filter_fun!(queryable, %__MODULE__{type: :boolean, fun: fun}, true)
       when is_function(fun, 1),
       do: ok_or_raise(fun.(queryable))

  defp apply_filter_fun!(queryable, %__MODULE__{type: :boolean, fun: fun}, false)
       when is_function(fun, 1) do
    case fun.(queryable) do
      {queryable, dynamic} -> {queryable, dynamic(not (^dynamic))}
      other -> raise_invalid_return!(other)
    end
  end

  defp apply_filter_fun!(queryable, %__MODULE__{fun: fun}, value) when is_function(fun, 2),
    do: ok_or_raise(fun.(queryable, value))

  defp apply_filter_fun!(_q, %__MODULE__{} = definition, value) do
    raise RuntimeError, """
    Invalid filter function for filter: #{inspect(definition)} and value: #{inspect(value)}.

    Filter function must have an arity of 1 (only for :boolean fields) or 2.
    """
  end

  defp ok_or_raise({queryable, dynamic}), do: {queryable, dynamic}
  defp ok_or_raise(other), do: raise_invalid_return!(other)

  defp raise_invalid_return!(invalid) do
    raise RuntimeError, """
    Invalid return value from filter function: #{inspect(invalid)}.

    Filter function must return {queryable, dynamic}.
    """
  end

  @doc false
  def validate_value(%__MODULE__{type: type, values: values}, value) do
    cond do
      not value_type_valid?(type, value) ->
        {:error, {:invalid_type, type: type, value: value}}

      values == [] or values == nil ->
        :ok

      value_valid?(type, value, values) ->
        :ok

      true ->
        {:error, {:invalid_value, values: values, value: value}}
    end
  end

  defp value_valid?({:list, subtype}, value, values),
    do: Enum.all?(value, &value_valid?(subtype, &1, values))

  # Values come in one of two shapes:
  #   - flat:    `[{value, label}, ...]`
  #   - grouped: `[{group_label, [{value, label}, ...]}, ...]`
  # `Enum.any?` with a guard distinguishes — grouped tuples nest a list
  # in the second element, flat tuples nest a string label.
  defp value_valid?(_type, value, values) do
    Enum.any?(values, fn
      {_label, options} when is_list(options) ->
        Enum.any?(options, fn {v, _label} -> v == value end)

      {v, _label} ->
        v == value
    end)
  end

  defp value_type_valid?({:range, type}, %Range{from: from, to: to}) do
    (is_nil(from) or value_type_valid?(type, from)) and
      (is_nil(to) or value_type_valid?(type, to)) and
      not (is_nil(from) and is_nil(to))
  end

  defp value_type_valid?({:list, type}, values) when is_list(values),
    do: Enum.all?(values, &value_type_valid?(type, &1))

  defp value_type_valid?({:string, :email}, v), do: is_binary(v)
  defp value_type_valid?({:string, :websearch}, v), do: is_binary(v)
  defp value_type_valid?({:string, :uuid}, v), do: Emisar.Repo.valid_uuid?(v)
  defp value_type_valid?(:string, v), do: is_binary(v)
  defp value_type_valid?(:boolean, v), do: is_boolean(v)
  defp value_type_valid?(:integer, v), do: is_integer(v)
  defp value_type_valid?(:number, v), do: is_number(v)
  defp value_type_valid?(:date, %Date{}), do: true
  defp value_type_valid?(:datetime, %DateTime{}), do: true
  defp value_type_valid?(:datetime, %NaiveDateTime{}), do: true
  defp value_type_valid?(_type, _value), do: false

  def merge_dynamic(dynamic, nil), do: dynamic
  def merge_dynamic(nil, dynamic), do: dynamic
  def merge_dynamic(a, b), do: dynamic(^a and ^b)
end

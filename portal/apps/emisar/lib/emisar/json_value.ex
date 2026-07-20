defmodule Emisar.JSONValue do
  @moduledoc "Structural limits for decoded JSON from untrusted boundaries."

  @doc "Validate an already-decoded JSON value against depth and node limits."
  def validate(value, opts) do
    max_depth = Keyword.fetch!(opts, :max_depth)
    max_nodes = Keyword.fetch!(opts, :max_nodes)

    case walk(value, 1, 0, max_depth, max_nodes) do
      {:ok, _nodes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp walk(_value, depth, _nodes, max_depth, _max_nodes) when depth > max_depth,
    do: {:error, :too_deep}

  defp walk(_value, _depth, nodes, _max_depth, max_nodes) when nodes >= max_nodes,
    do: {:error, :too_many_nodes}

  defp walk(%{} = value, depth, nodes, max_depth, max_nodes) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn
      {key, child}, {:ok, count} when is_binary(key) ->
        case walk(child, depth + 1, count, max_depth, max_nodes) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_value}}
    end)
  end

  defp walk(value, depth, nodes, max_depth, max_nodes) when is_list(value) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn child, {:ok, count} ->
      case walk(child, depth + 1, count, max_depth, max_nodes) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp walk(value, _depth, nodes, _max_depth, _max_nodes)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, nodes + 1}

  defp walk(_value, _depth, _nodes, _max_depth, _max_nodes), do: {:error, :invalid_value}
end

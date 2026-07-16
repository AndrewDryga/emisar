defmodule EmisarWeb.MCP.ToolParams do
  @moduledoc """
  Scalar parameter coercion for the fixed MCP tools. LLM clients routinely
  serialize scalars as JSON strings ("limit": "50", "issues_only": "true"), and
  an error that only restates the expected range sends the model hunting the
  wrong fault — observed live: limit sent as the string "50", told "must be an
  integer from 1 to 50", the model retried "25" (still a string) and gave up.
  Benign read parameters coerce the canonical string form; a genuine mismatch
  names the received JSON type so the model can self-correct in one step.
  """

  @doc """
  Parses a bounded integer tool parameter. nil takes `default`; a canonical
  integer string coerces. Returns `{:ok, integer}` or `{:error, message}`.
  """
  def limit(nil, default, _max), do: {:ok, default}

  def limit(value, _default, max) when is_integer(value) do
    if value in 1..max do
      {:ok, value}
    else
      {:error, "limit must be a JSON integer from 1 to #{max}."}
    end
  end

  def limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> limit(parsed, default, max)
      _ -> {:error, limit_type_message(value, max)}
    end
  end

  def limit(value, _default, max), do: {:error, limit_type_message(value, max)}

  @doc """
  Parses a boolean tool parameter. nil takes `default`; the literal strings
  "true"/"false" coerce. Returns `{:ok, boolean}` or `{:error, message}`.
  """
  def boolean(nil, default, _name), do: {:ok, default}
  def boolean(value, _default, _name) when is_boolean(value), do: {:ok, value}
  def boolean("true", _default, _name), do: {:ok, true}
  def boolean("false", _default, _name), do: {:ok, false}

  def boolean(value, _default, name) do
    {:error, "#{name} must be a JSON boolean; it was sent as #{json_type(value)}."}
  end

  defp limit_type_message(value, max) do
    "limit must be a JSON integer from 1 to #{max}; it was sent as #{json_type(value)}."
  end

  defp json_type(value) when is_binary(value), do: "a string"
  defp json_type(value) when is_boolean(value), do: "a boolean"
  defp json_type(value) when is_integer(value), do: "a number"
  defp json_type(value) when is_float(value), do: "a non-integer number"
  defp json_type(value) when is_list(value), do: "an array"
  defp json_type(value) when is_map(value), do: "an object"
  defp json_type(nil), do: "null"
end

defmodule EmisarWeb.MCP.ClientMetadata do
  @moduledoc """
  Validates the self-reported `Emisar-Client-Metadata` request header — the
  operator-configured key/value map an MCP caller sends so its Emisar activity
  can be correlated with the customer's own MDM / EDR / device inventory in the
  audit log and SIEM export.

  It is UNTRUSTED, self-reported enrichment: snapshotted onto the MCP action run
  for audit/SIEM, never a policy, approval, posture, or authorization input.

  The limits mirror the Go bridge's `parseClientMetadata` — both boundaries
  enforce them independently because the header is untrusted (a direct HTTP
  caller, or a modified bridge, can send anything): a JSON object of at most 10
  string keys to string-or-number values, keys ≤ 128 and values ≤ 512
  characters. Numeric values are stored as their string form. Any malformed
  input, disallowed value type, or exceeded limit fails closed — the request is
  rejected and nothing partial is stored.
  """

  @max_keys 10
  @max_key_length 128
  @max_value_length 512

  @doc """
  Parse the raw `Emisar-Client-Metadata` header value(s) into a validated
  `%{String.t() => String.t()}` map. Returns `{:ok, %{}}` when the header is
  absent or blank, and `{:error, message}` on any malformed input, disallowed
  value type, or exceeded limit.
  """
  def parse([]), do: {:ok, %{}}
  def parse([raw | _]), do: parse(raw)
  def parse(nil), do: {:ok, %{}}

  def parse(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" -> {:ok, %{}}
      trimmed -> decode(trimmed)
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> validate(map)
      {:ok, _other} -> {:error, "client metadata must be a JSON object"}
      {:error, _reason} -> {:error, "client metadata is not valid JSON"}
    end
  end

  defp validate(map) when map_size(map) > @max_keys,
    do: {:error, "client metadata has more than #{@max_keys} keys"}

  defp validate(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case validate_pair(key, value) do
        {:ok, string_value} -> {:cont, {:ok, Map.put(acc, key, string_value)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp validate_pair(key, value) do
    with :ok <- validate_key(key) do
      validate_value(key, value)
    end
  end

  defp validate_key(key) when is_binary(key) do
    if String.length(key) > @max_key_length do
      {:error, "client metadata key #{inspect(key)} exceeds #{@max_key_length} characters"}
    else
      :ok
    end
  end

  defp validate_value(key, value) when is_binary(value) do
    if String.length(value) > @max_value_length do
      {:error,
       "client metadata value for #{inspect(key)} exceeds #{@max_value_length} characters"}
    else
      {:ok, value}
    end
  end

  defp validate_value(key, value) when is_number(value) do
    string = to_string(value)

    if String.length(string) > @max_value_length do
      {:error,
       "client metadata value for #{inspect(key)} exceeds #{@max_value_length} characters"}
    else
      {:ok, string}
    end
  end

  defp validate_value(key, _value),
    do: {:error, "client metadata value for #{inspect(key)} must be a string or number"}
end

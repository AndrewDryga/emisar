defmodule EmisarWeb.MCP.RawJSON do
  @moduledoc """
  Parses the cached MCP request body without normalizing JSON values.

  The ordinary Plug/Jason projection remains useful for routing, but it cannot
  detect duplicate keys or preserve numeric spelling. This parser supplies the
  security boundary: it rejects ambiguous JSON recursively and records byte
  offsets so signed action arguments can be sliced from the original body.
  """

  defmodule Node do
    @moduledoc false
    defstruct [:type, :start, :stop, :value, children: nil]

    @type t :: %__MODULE__{
            type: atom(),
            start: non_neg_integer(),
            stop: non_neg_integer(),
            value: term(),
            children: %{optional(String.t()) => t()} | [t()] | nil
          }
  end

  defmodule Number do
    @moduledoc "An exact JSON number token retained without float normalization."
    defstruct [:raw]

    @type t :: %__MODULE__{raw: binary()}
  end

  @max_depth 64
  @max_action_args_bytes 32_768
  @number ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/

  @type path_segment :: String.t() | non_neg_integer()
  @type parse_error ::
          :invalid_utf8
          | :invalid_json
          | :nesting_too_deep
          | :action_args_too_large
          | {:duplicate_key, [path_segment()]}

  @doc "Parse one complete UTF-8 JSON value and retain every value's byte range."
  @spec parse(binary()) :: {:ok, Node.t()} | {:error, parse_error()}
  def parse(raw) when is_binary(raw) do
    if String.valid?(raw) do
      start = skip_whitespace(raw, 0)

      with {:ok, node, position} <- parse_value(raw, start, 0, []),
           true <- skip_whitespace(raw, position) == byte_size(raw) do
        {:ok, node}
      else
        false -> {:error, :invalid_json}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_utf8}
    end
  end

  @doc "Fetch a child by decoded object key or array index."
  @spec fetch(Node.t(), [path_segment()]) :: {:ok, Node.t()} | :error
  def fetch(%Node{} = node, []), do: {:ok, node}

  def fetch(%Node{type: :object, children: children}, [key | rest]) when is_binary(key) do
    case Map.fetch(children, key) do
      {:ok, child} -> fetch(child, rest)
      :error -> :error
    end
  end

  def fetch(%Node{type: :array, children: children}, [index | rest])
      when is_integer(index) and index >= 0 do
    case Enum.fetch(children, index) do
      {:ok, child} -> fetch(child, rest)
      :error -> :error
    end
  end

  def fetch(%Node{}, _path), do: :error

  @doc "Return the exact original bytes occupied by a parsed value."
  @spec slice(binary(), Node.t()) :: binary()
  def slice(raw, %Node{start: start, stop: stop}) when is_binary(raw),
    do: binary_part(raw, start, stop - start)

  @doc "Decode one JSON object while retaining every number's exact token."
  @spec decode_object(binary()) :: {:ok, map()} | {:error, parse_error()}
  def decode_object(raw) when is_binary(raw) do
    case parse(raw) do
      {:ok, %Node{type: :object} = node} -> {:ok, to_term(node)}
      {:ok, %Node{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Replace sensitive top-level action arguments before display."
  @spec redact(map(), [String.t()]) :: map()
  def redact(args, names) when is_map(args) and is_list(names) do
    Enum.reduce(names, args, fn name, redacted ->
      if Map.has_key?(redacted, name),
        do: Map.put(redacted, name, "[REDACTED]"),
        else: redacted
    end)
  end

  @doc "Extract exact mutation argument sidecars from one tools/call request."
  @spec tool_call(binary()) ::
          {:ok,
           %{
             name: String.t(),
             arguments: binary(),
             action_args: binary() | nil
           }}
          | {:error, parse_error()}
  def tool_call(raw) when is_binary(raw) do
    with {:ok, root} <- parse(raw),
         {:ok, %Node{type: :string, value: "tools/call"}} <- fetch(root, ["method"]),
         {:ok, %Node{type: :string, value: name}} <- fetch(root, ["params", "name"]),
         {:ok, %Node{type: :object} = arguments} <- fetch(root, ["params", "arguments"]),
         {:ok, action_args} <- action_args(raw, name, arguments) do
      {:ok,
       %{
         name: name,
         arguments: slice(raw, arguments),
         action_args: action_args
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_json}
    end
  end

  defp action_args(raw, "run_action", arguments) do
    with {:ok, %Node{type: :object} = args} <- fetch(arguments, ["args"]),
         :ok <- check_action_args_size(args) do
      {:ok, slice(raw, args)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_json}
    end
  end

  defp action_args(_raw, _name, _arguments), do: {:ok, nil}

  defp check_action_args_size(%Node{start: start, stop: stop}) do
    if stop - start <= @max_action_args_bytes, do: :ok, else: {:error, :action_args_too_large}
  end

  defp parse_value(_raw, _position, depth, _path) when depth > @max_depth,
    do: {:error, :nesting_too_deep}

  defp parse_value(raw, position, depth, path) do
    case byte_at(raw, position) do
      ?{ -> parse_object(raw, position, depth, path)
      ?[ -> parse_array(raw, position, depth, path)
      ?" -> parse_string(raw, position)
      ?t -> parse_literal(raw, position, "true", :boolean, true)
      ?f -> parse_literal(raw, position, "false", :boolean, false)
      ?n -> parse_literal(raw, position, "null", :null, nil)
      byte when byte == ?- or byte in ?0..?9 -> parse_number(raw, position)
      _ -> {:error, :invalid_json}
    end
  end

  defp parse_object(raw, start, depth, path) do
    position = skip_whitespace(raw, start + 1)

    if byte_at(raw, position) == ?} do
      {:ok, %Node{type: :object, start: start, stop: position + 1, children: %{}}, position + 1}
    else
      parse_members(raw, start, position, depth, path, %{})
    end
  end

  defp parse_members(raw, start, position, depth, path, members) do
    with {:ok, %Node{type: :string, value: key}, after_key} <- parse_string(raw, position),
         false <- Map.has_key?(members, key),
         colon <- skip_whitespace(raw, after_key),
         true <- byte_at(raw, colon) == ?:,
         value_start <- skip_whitespace(raw, colon + 1),
         {:ok, value, after_value} <- parse_value(raw, value_start, depth + 1, [key | path]) do
      members = Map.put(members, key, value)
      continue_object(raw, start, after_value, depth, path, members)
    else
      true -> {:error, {:duplicate_key, Enum.reverse([decoded_key(raw, position) | path])}}
      false -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_json}
    end
  end

  defp continue_object(raw, start, after_value, depth, path, members) do
    position = skip_whitespace(raw, after_value)

    case byte_at(raw, position) do
      ?, ->
        next = skip_whitespace(raw, position + 1)

        if byte_at(raw, next) == ?} do
          {:error, :invalid_json}
        else
          parse_members(raw, start, next, depth, path, members)
        end

      ?} ->
        {:ok, %Node{type: :object, start: start, stop: position + 1, children: members},
         position + 1}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_array(raw, start, depth, path) do
    position = skip_whitespace(raw, start + 1)

    if byte_at(raw, position) == ?] do
      {:ok, %Node{type: :array, start: start, stop: position + 1, children: []}, position + 1}
    else
      parse_elements(raw, start, position, depth, path, [], 0)
    end
  end

  defp parse_elements(raw, start, position, depth, path, elements, index) do
    with {:ok, value, after_value} <- parse_value(raw, position, depth + 1, [index | path]) do
      elements = [value | elements]
      continue_array(raw, start, after_value, depth, path, elements, index + 1)
    end
  end

  defp continue_array(raw, start, after_value, depth, path, elements, index) do
    position = skip_whitespace(raw, after_value)

    case byte_at(raw, position) do
      ?, ->
        next = skip_whitespace(raw, position + 1)

        if byte_at(raw, next) == ?] do
          {:error, :invalid_json}
        else
          parse_elements(raw, start, next, depth, path, elements, index)
        end

      ?] ->
        {:ok,
         %Node{type: :array, start: start, stop: position + 1, children: Enum.reverse(elements)},
         position + 1}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_string(raw, start) do
    if byte_at(raw, start) == ?" do
      with {:ok, stop} <- scan_string(raw, start + 1),
           {:ok, value} <- Jason.decode(binary_part(raw, start, stop - start)) do
        {:ok, %Node{type: :string, start: start, stop: stop, value: value}, stop}
      else
        _ -> {:error, :invalid_json}
      end
    else
      {:error, :invalid_json}
    end
  end

  defp scan_string(raw, position) do
    case byte_at(raw, position) do
      nil -> {:error, :invalid_json}
      ?" -> {:ok, position + 1}
      ?\\ -> continue_string_escape(raw, position + 1)
      byte when byte < 0x20 -> {:error, :invalid_json}
      _ -> scan_string(raw, position + 1)
    end
  end

  defp continue_string_escape(raw, position) do
    case scan_escape(raw, position) do
      {:continue, next} -> scan_string(raw, next)
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_escape(raw, position) do
    case byte_at(raw, position) do
      byte when byte in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] ->
        {:continue, position + 1}

      ?u ->
        scan_unicode_escape(raw, position + 1)

      _ ->
        {:error, :invalid_json}
    end
  end

  defp scan_unicode_escape(raw, hex_start) do
    with {:ok, codepoint} <- hex_code(raw, hex_start) do
      next = hex_start + 4

      cond do
        codepoint in 0xD800..0xDBFF ->
          with ?\\ <- byte_at(raw, next),
               ?u <- byte_at(raw, next + 1),
               {:ok, low} when low in 0xDC00..0xDFFF <- hex_code(raw, next + 2) do
            {:continue, next + 6}
          else
            _ -> {:error, :invalid_json}
          end

        codepoint in 0xDC00..0xDFFF ->
          {:error, :invalid_json}

        true ->
          {:continue, next}
      end
    end
  end

  defp hex_code(raw, start) do
    if start + 4 <= byte_size(raw) do
      raw
      |> binary_part(start, 4)
      |> Integer.parse(16)
      |> case do
        {value, ""} -> {:ok, value}
        _ -> {:error, :invalid_json}
      end
    else
      {:error, :invalid_json}
    end
  end

  defp parse_literal(raw, start, literal, type, value) do
    if starts_at?(raw, start, literal) do
      stop = start + byte_size(literal)
      {:ok, %Node{type: type, start: start, stop: stop, value: value}, stop}
    else
      {:error, :invalid_json}
    end
  end

  defp parse_number(raw, start) do
    remaining = binary_part(raw, start, byte_size(raw) - start)

    case Regex.run(@number, remaining) do
      [number] ->
        stop = start + byte_size(number)
        {:ok, %Node{type: :number, start: start, stop: stop, value: number}, stop}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp to_term(%Node{type: :object, children: children}) do
    Map.new(children, fn {key, value} -> {key, to_term(value)} end)
  end

  defp to_term(%Node{type: :array, children: children}), do: Enum.map(children, &to_term/1)
  defp to_term(%Node{type: :number, value: raw}), do: %Number{raw: raw}
  defp to_term(%Node{value: value}), do: value

  defp skip_whitespace(raw, position) do
    if byte_at(raw, position) in [0x20, 0x09, 0x0A, 0x0D],
      do: skip_whitespace(raw, position + 1),
      else: position
  end

  defp starts_at?(raw, start, expected) do
    size = byte_size(expected)
    start + size <= byte_size(raw) and binary_part(raw, start, size) == expected
  end

  defp byte_at(raw, position) when position >= 0 and position < byte_size(raw),
    do: :binary.at(raw, position)

  defp byte_at(_raw, _position), do: nil

  defp decoded_key(raw, position) do
    case parse_string(raw, position) do
      {:ok, %Node{value: value}, _position} -> value
      _ -> "<invalid>"
    end
  end
end

defimpl Jason.Encoder, for: EmisarWeb.MCP.RawJSON.Number do
  @number ~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/

  def encode(%{raw: raw}, _opts) do
    if Regex.match?(@number, raw), do: raw, else: raise(ArgumentError, "invalid JSON number")
  end
end

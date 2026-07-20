defmodule EmisarWeb.MCP.ValidationError do
  @moduledoc """
  Builds the fixed MCP argument-validation failure and logs its safe metadata.

  Tool arguments are hostile. Human-facing messages may explain a correction,
  but observability is derived only from the bounded machine fields in
  `details`; raw values and messages never reach the log event.
  """

  alias EmisarWeb.MCP.{InputContract, RawJSON, SchemaRegistry}
  require Logger

  @stages ~w(tool_call arguments action_arguments)
  @kinds ~w(missing unknown type format enum range size unique conflict dependency schema)
  @codes ~w(
    required unknown unknown_arg type format range conflict dependency unique size schema
    max_length max_items enum allowed min max min_duration max_duration duration path
  )
  # One shared code→kind table: `details.kind` is derived from the first
  # rendered issue instead of a second per-caller classification.
  @kind_for_code %{
    "required" => "missing",
    "unknown" => "unknown",
    "unknown_arg" => "unknown",
    "type" => "type",
    "format" => "format",
    "duration" => "format",
    "path" => "format",
    "enum" => "enum",
    "allowed" => "enum",
    "range" => "range",
    "min" => "range",
    "max" => "range",
    "min_duration" => "range",
    "max_duration" => "range",
    "size" => "size",
    "max_length" => "size",
    "max_items" => "size",
    "unique" => "unique",
    "conflict" => "conflict",
    "dependency" => "dependency",
    "schema" => "schema"
  }
  @action_id ~r/\A[a-z][a-z0-9_-]*(\.[a-z][a-z0-9_-]*)+\z/
  @max_issues 8
  @max_message_chars 512
  @path_segment ~r/\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/

  @type issue :: %{path: String.t(), code: String.t()}

  @doc "Returns one safe issue from server-owned JSON-path segments and a fixed code."
  @spec issue([String.t() | atom()], String.t() | atom()) :: issue()
  def issue(segments, code) when is_list(segments) do
    %{path: issue_path(segments), code: fixed(code, @codes, "schema")}
  end

  @doc "Builds the typed details shared by tool results and JSON-RPC argument errors."
  @spec details(keyword()) :: map()
  def details(opts \\ []) do
    issues =
      opts
      |> Keyword.get(:issues, [issue([], "schema")])
      |> Enum.take(@max_issues)
      |> Enum.map(&normalize_issue/1)
      |> Enum.sort_by(&{&1.path, &1.code})

    issues = if issues == [], do: [issue([], "schema")], else: issues

    %{
      schema_version: SchemaRegistry.schema_version(),
      stage: fixed(Keyword.get(opts, :stage), @stages, "arguments"),
      kind: Map.fetch!(@kind_for_code, hd(issues).code),
      issues: issues
    }
  end

  @doc "Builds the fixed pre-dispatch MCP tool error result."
  @spec payload(String.t(), keyword()) :: map()
  def payload(message, opts \\ []) do
    %{
      ok: false,
      error: %{
        code: "invalid_args",
        message: bounded_message(message),
        retryable: false,
        details: details(opts)
      },
      dispatch_started: false
    }
  end

  @doc "Emits the single safe event for a normalized validation failure."
  @spec log(Plug.Conn.t(), term(), map()) :: :ok
  def log(conn, tool, payload) do
    case validation_details(payload) do
      %{} = details -> log_details(conn, tool, details)
      nil -> :ok
    end
  end

  @doc "Emits the safe event for a JSON-RPC argument error."
  @spec log_details(Plug.Conn.t(), term(), map()) :: :ok
  def log_details(conn, tool, details) do
    stage = fixed(field(details, :stage), @stages, "arguments")
    kind = fixed(field(details, :kind), @kinds, "schema")

    metadata =
      [
        mcp_validation_stage: stage,
        mcp_validation_kind: kind,
        mcp_validation_issues:
          details |> field(:issues) |> safe_log_issues(tool) |> Enum.join(","),
        mcp_schema_version: SchemaRegistry.schema_version()
      ]
      |> Kernel.++(client_metadata(conn, tool))

    Logger.info("mcp.validation_failed", metadata)
  end

  @doc "Emits one privacy-safe event for a well-formed but unknown string tool name."
  @spec log_unknown_tool(Plug.Conn.t(), String.t()) :: :ok
  def log_unknown_tool(conn, tool) when is_binary(tool) do
    metadata =
      [mcp_unknown_tool_shape: unknown_tool_shape(tool)]
      |> Kernel.++(client_metadata(conn, tool))

    Logger.info("mcp.unknown_tool", metadata)
  end

  @doc "Sanitizes a bridge version before persistence or logging."
  @spec safe_version(term()) :: String.t() | nil
  def safe_version(value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) in 1..64 do
      case Version.parse(value) do
        {:ok, version} -> to_string(version)
        :error -> nil
      end
    else
      nil
    end
  end

  def safe_version(_value), do: nil

  defp validation_details(payload) do
    error = field(payload, :error)

    if is_map(error) and field(error, :code) == "invalid_args" do
      case field(error, :details) do
        %{} = details -> details
        _ -> nil
      end
    end
  end

  defp client_name(conn) do
    case conn.assigns[:api_key] do
      %{last_client_info: %{"name" => name}} -> client_category(name)
      _ -> nil
    end
  end

  defp client_category(name) when is_binary(name) do
    normalized = String.downcase(name)

    cond do
      String.contains?(normalized, "claude") -> "claude"
      String.contains?(normalized, "codex") -> "codex"
      String.contains?(normalized, "chatgpt") -> "chatgpt"
      String.contains?(normalized, "cursor") -> "cursor"
      String.contains?(normalized, "gemini") -> "gemini"
      String.contains?(normalized, "vscode") -> "vscode"
      true -> "other"
    end
  end

  defp client_category(_name), do: nil

  defp client_version(conn) do
    case conn.assigns[:api_key] do
      %{last_client_info: %{} = info} -> info |> Map.get("version") |> safe_version()
      _ -> nil
    end
  end

  defp client_lineage(conn) do
    case conn.assigns[:api_key] do
      %{account_id: account_id, credential_lineage_id: lineage_id}
      when is_binary(account_id) and is_binary(lineage_id) ->
        hmac_hex(["mcp-client-lineage-v1", 0, account_id, 0, lineage_id])

      _ ->
        nil
    end
  end

  defp request_bridge_version(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      ["emisar-mcp/" <> rest | _] -> rest |> String.split() |> List.first() |> safe_version()
      _ -> nil
    end
  end

  defp client_metadata(conn, tool) do
    [
      mcp_tool: safe_tool(tool),
      mcp_call_fingerprint: call_fingerprint(conn),
      mcp_client_lineage: client_lineage(conn),
      mcp_client_name: client_name(conn),
      mcp_client_version: client_version(conn),
      mcp_bridge_version: request_bridge_version(conn)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp safe_tool(tool) when is_binary(tool) do
    if tool in SchemaRegistry.tool_names(), do: tool, else: "unknown"
  end

  defp safe_tool(_tool), do: "unknown"

  defp unknown_tool_shape(tool) do
    if Regex.match?(@action_id, tool), do: "action_id", else: "other"
  end

  # Keyed over the exact `params` bytes of the cached request body, so equal
  # calls correlate across log events while values never appear in the log.
  defp call_fingerprint(conn) do
    with %{account_id: account_id, credential_lineage_id: lineage_id}
         when is_binary(account_id) and is_binary(lineage_id) <- conn.assigns[:api_key],
         raw_body when is_binary(raw_body) <- conn.assigns[:raw_body],
         %RawJSON.Node{} = tree <- conn.assigns[:mcp_json_tree],
         {:ok, params} <- RawJSON.fetch(tree, ["params"]) do
      hmac_hex(["mcp-call-v1", 0, account_id, 0, lineage_id, 0, RawJSON.slice(raw_body, params)])
    else
      _other -> nil
    end
  end

  defp hmac_hex(payload) do
    key = Application.fetch_env!(:emisar, :mcp_telemetry_salt)
    mac = :crypto.mac(:hmac, :sha256, key, payload)
    Base.encode16(mac, case: :lower)
  end

  defp safe_log_issues(issues, tool) when is_list(issues) do
    known_fields = tool |> safe_tool() |> InputContract.known_root_fields()

    issues
    |> Enum.take(@max_issues)
    |> Enum.map(&normalize_issue/1)
    |> Enum.map(&"#{safe_log_path(&1.path, known_fields)}:#{&1.code}")
    |> Enum.uniq()
  end

  defp safe_log_issues(_issues, _tool), do: ["$:schema"]

  defp safe_log_path("$." <> rest, known_fields) do
    root = rest |> String.split(".", parts: 2) |> hd()
    if MapSet.member?(known_fields, root), do: "$.#{root}", else: "$"
  end

  defp safe_log_path(_path, _known_fields), do: "$"

  defp normalize_issue(%{} = value) do
    path = field(value, :path)
    code = field(value, :code)

    %{
      path: if(valid_path?(path), do: path, else: "$"),
      code: fixed(code, @codes, "schema")
    }
  end

  defp normalize_issue(_value), do: issue([], "schema")

  defp issue_path(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      Enum.reduce(segments, "$", fn segment, path -> path <> "." <> to_string(segment) end)
    else
      "$"
    end
  end

  defp valid_segment?(segment) when is_atom(segment),
    do: segment |> Atom.to_string() |> valid_segment?()

  defp valid_segment?(segment) when is_binary(segment), do: Regex.match?(@path_segment, segment)
  defp valid_segment?(_segment), do: false

  defp valid_path?("$"), do: true

  defp valid_path?("$." <> rest) do
    rest |> String.split(".") |> Enum.all?(&valid_segment?/1)
  end

  defp valid_path?(_path), do: false

  defp fixed(value, allowed, fallback) when is_atom(value),
    do: value |> Atom.to_string() |> fixed(allowed, fallback)

  defp fixed(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp fixed(_value, _allowed, fallback), do: fallback

  defp bounded_message(message) when is_binary(message),
    do: String.slice(message, 0, @max_message_chars)

  defp bounded_message(_message), do: "Arguments do not match the fixed contract."

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

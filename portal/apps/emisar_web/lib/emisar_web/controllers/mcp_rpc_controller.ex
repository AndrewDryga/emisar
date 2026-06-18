defmodule EmisarWeb.MCPRpcController do
  @moduledoc """
  MCP-over-HTTP — JSON-RPC 2.0 on a single POST endpoint at
  `/api/mcp/rpc`. The canonical MCP server implementation. Same
  Bearer-token auth as the REST routes under `/api/mcp/*`.

  ## Methods implemented

    * `initialize`        — capabilities + protocolVersion + serverInfo
    * `ping`              — `{}`
    * `tools/list`        — every action the API key can dispatch, plus
                            the synthetic `wait_for_run`, `list_runbooks`,
                            and `get_runbook` tools
    * `tools/call`        — dispatch a run; result is `{content, isError}`
                            in MCP content-block shape
    * `notifications/*`   — silently dropped (per JSON-RPC notifications)

  Anything else → JSON-RPC `-32601 method not found`. Parse errors →
  `-32700`. Auth failures → JSON-RPC `-32001 unauthorized`.

  ## Stdio bridge

  `mcp/main.go` is a thin transport shim that reads stdio JSON-RPC,
  forwards the same JSON body to this endpoint, and writes the JSON-RPC
  response back to stdout. All MCP shaping (tool descriptors, content
  blocks, synthetic tools) lives in this controller + `MCP.Service` +
  `MCP.ContentBlocks`.
  """

  use EmisarWeb, :controller

  alias Emisar.ApiKeys
  alias EmisarWeb.MCP.{Auth, ContentBlocks, Idempotency, Instructions, Service}

  @protocol_version "2024-11-05"
  @server_name "emisar"

  # A leaked key is the abuse vector — cap per key (falls back to IP for
  # unauthenticated hammering). 300/min is generous for a real LLM agent.
  plug EmisarWeb.Plugs.RateLimit, bucket: "mcp", limit: 300, window_ms: 60_000, by: :bearer

  plug :authenticate

  # POST /api/mcp/rpc
  def handle(conn, %{"jsonrpc" => "2.0", "method" => method} = req) do
    id = Map.get(req, "id")
    params = Map.get(req, "params") || %{}
    conn = maybe_emit_session_id(conn, method)

    case dispatch(conn, method, params) do
      :no_reply ->
        # JSON-RPC notification — RFC says no response body.
        send_resp(conn, 202, "")

      {:ok, result} ->
        json(conn, %{jsonrpc: "2.0", id: id, result: result})

      {:error, code, message} ->
        json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

      {:error, code, message, data} ->
        json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message, data: data}})
    end
  end

  def handle(conn, _bad_request) do
    conn
    |> put_status(:bad_request)
    |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: "invalid request"}})
  end

  # -- Method dispatch ------------------------------------------------

  defp dispatch(conn, "initialize", params) do
    capture_client_info(conn, params)

    {:ok,
     %{
       protocolVersion: @protocol_version,
       serverInfo: %{name: @server_name, version: app_version()},
       capabilities: %{tools: %{listChanged: false}},
       instructions: Instructions.text()
     }}
  end

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(conn, "tools/list", _params) do
    with :ok <- require_scope(conn, "actions:read") do
      tools =
        Service.list_tools(conn) ++
          [
            ContentBlocks.wait_for_run_tool(),
            ContentBlocks.list_runbooks_tool(),
            ContentBlocks.get_runbook_tool(),
            ContentBlocks.recent_runs_tool()
          ]

      {:ok, %{tools: tools}}
    end
  end

  defp dispatch(conn, "tools/call", params) do
    name = Map.get(params, "name", "")
    args = Map.get(params, "arguments") || %{}

    cond do
      name == "" ->
        {:error, -32602, "missing tool name"}

      name == "wait_for_run" ->
        with :ok <- require_scope(conn, "actions:read") do
          handle_wait_for_run(conn, args)
        end

      name == "list_runbooks" ->
        with :ok <- require_scope(conn, "actions:read") do
          handle_list_runbooks(conn)
        end

      name == "get_runbook" ->
        with :ok <- require_scope(conn, "actions:read") do
          handle_get_runbook(conn, args)
        end

      name == "recent_runs" ->
        with :ok <- require_scope(conn, "actions:read") do
          handle_recent_runs(conn, args)
        end

      true ->
        with :ok <- require_scope(conn, "actions:execute") do
          handle_tool_call(conn, name, args)
        end
    end
  end

  defp dispatch(_conn, "notifications/" <> _, _params), do: :no_reply

  defp dispatch(_conn, method, _params),
    do: {:error, -32601, "method not found", method}

  # -- Tool call ------------------------------------------------------

  defp handle_tool_call(conn, name, args) do
    {runner_names, reason, wait, attestation, action_args} = split_call_args(args)
    idempotency_key = Idempotency.resolve(conn, args)

    # Omitting `wait` means "block for the result" — the default has to
    # be the full window, not 0, or a tool call returns a bare
    # status=sent with no output and the LLM has nothing to act on.
    # `parse_wait(nil)` returns 0, so handle the omitted case explicitly
    # here; an explicit `wait: "0"` from the caller still means
    # fire-and-forget.
    wait_ms =
      case wait do
        blank when blank in [nil, ""] ->
          Service.max_wait_ms()

        _ ->
          case Service.parse_wait(wait, Service.max_wait_ms()) do
            {:ok, ms} -> ms
            :error -> Service.max_wait_ms()
          end
      end

    opts = %{
      runner_names: runner_names,
      reason: reason,
      wait_ms: wait_ms,
      idempotency_key: idempotency_key,
      mcp_session_id: req_session_id(conn),
      attestation: attestation
    }

    case Service.dispatch_tool(conn, name, action_args, opts) do
      {:ok, runs} ->
        {content, is_err} = ContentBlocks.from_runs(runs)
        {:ok, %{content: content, isError: is_err}}

      {:error, :runner_required, candidates} ->
        msg =
          "Multiple runners advertise this action. Pick one or more by name and retry " <>
            "with `runners: [\"name\"]`. Candidates: " <> Enum.join(candidates, ", ")

        {content, _} = ContentBlocks.error_content("Runner required", msg)
        {:ok, %{content: content, isError: true}}

      {:error, :runner_not_found, runner} ->
        {content, _} =
          ContentBlocks.error_content(
            "Runner not found",
            "No runner named `#{runner}` in this account."
          )

        {:ok, %{content: content, isError: true}}

      {:error, :runner_not_allowed, runner, why} ->
        {content, _} = ContentBlocks.error_content("Runner not allowed", "`#{runner}`: #{why}")
        {:ok, %{content: content, isError: true}}

      {:error, :no_runner_available, :unknown_action} ->
        {content, _} =
          ContentBlocks.error_content(
            "Action not found",
            "No currently-connected runner advertises `#{name}`. Re-call tools/list to refresh; " <>
              "if it's still missing, the runner is likely offline or the pack isn't loaded — " <>
              "tell the user to check the runner is online (Runners page). Don't retry in a loop."
          )

        {:ok, %{content: content, isError: true}}

      {:error, :no_runner_available, :scope_blocked} ->
        {content, _} =
          ContentBlocks.error_content(
            "No runner in scope",
            "`#{name}` exists but no runner you're allowed to reach advertises it. This is an " <>
              "access grant, not a transient state — ask an admin to grant runner access. " <>
              "Retrying won't help."
          )

        {:ok, %{content: content, isError: true}}

      {:error, :too_many_runners, max} ->
        {content, _} =
          ContentBlocks.error_content(
            "Too many runners",
            "Cap is #{max} per call. Split the work into batches."
          )

        {:ok, %{content: content, isError: true}}
    end
  end

  # -- wait_for_run ---------------------------------------------------

  defp handle_wait_for_run(conn, args) do
    run_id = Map.get(args, "run_id")
    timeout = Map.get(args, "timeout", "300s")

    if not is_binary(run_id) or run_id == "" do
      {content, _} =
        ContentBlocks.error_content("Bad arguments", "wait_for_run requires `run_id` (string).")

      {:ok, %{content: content, isError: true}}
    else
      case Service.parse_wait(timeout, Service.max_get_run_wait_ms()) do
        :error ->
          {content, _} =
            ContentBlocks.error_content(
              "Bad timeout",
              "Expected a duration like \"60s\" or \"3m\" (max 5m)."
            )

          {:ok, %{content: content, isError: true}}

        {:ok, wait_ms} ->
          case Service.fetch_run(conn, run_id, wait_ms) do
            {:ok, payload, :terminal} ->
              {content, is_err} = ContentBlocks.from_run(payload)
              {:ok, %{content: content, isError: is_err}}

            {:ok, payload, :waiting} ->
              # Still in-flight — tell the LLM to call again.
              {content, _} = ContentBlocks.from_run(Map.put(payload, "waiting", "timeout"))
              {:ok, %{content: content, isError: false}}

            {:error, :not_found} ->
              {content, _} =
                ContentBlocks.error_content("Run not found", "No run with id `#{run_id}`.")

              {:ok, %{content: content, isError: true}}
          end
      end
    end
  end

  # -- Runbooks (read-only) -------------------------------------------

  defp handle_list_runbooks(conn) do
    case Service.list_runbooks(conn) do
      {:ok, summaries} ->
        {content, is_err} = ContentBlocks.from_runbook_list(summaries)
        {:ok, %{content: content, isError: is_err}}

      {:error, :unauthorized} ->
        {content, _} =
          ContentBlocks.error_content("Not allowed", "This API key can't read runbooks.")

        {:ok, %{content: content, isError: true}}
    end
  end

  defp handle_get_runbook(conn, args) do
    case Map.get(args, "runbook") do
      slug when is_binary(slug) and slug != "" ->
        case Service.get_runbook(conn, slug) do
          {:ok, detail} ->
            {content, is_err} = ContentBlocks.from_runbook_detail(detail)
            {:ok, %{content: content, isError: is_err}}

          {:error, :not_found} ->
            {content, _} =
              ContentBlocks.error_content(
                "Runbook not found",
                "No published runbook with slug or id `#{slug}`. Call list_runbooks to see them."
              )

            {:ok, %{content: content, isError: true}}

          {:error, :unauthorized} ->
            {content, _} =
              ContentBlocks.error_content("Not allowed", "This API key can't read runbooks.")

            {:ok, %{content: content, isError: true}}
        end

      _ ->
        {content, _} =
          ContentBlocks.error_content(
            "Bad arguments",
            "get_runbook requires `runbook` (a slug or id string)."
          )

        {:ok, %{content: content, isError: true}}
    end
  end

  # -- recent_runs ----------------------------------------------------

  defp handle_recent_runs(conn, args) do
    with {:ok, limit} <- parse_limit(Map.get(args, "limit")),
         {:ok, scope} <- parse_scope(Map.get(args, "scope")),
         {:ok, runner} <- parse_string_arg("runner", Map.get(args, "runner")),
         {:ok, action} <- parse_string_arg("action", Map.get(args, "action")),
         {:ok, runs} <- Service.recent_runs(conn, limit, scope, runner, action) do
      {content, is_err} = ContentBlocks.from_recent_runs(runs)
      {:ok, %{content: content, isError: is_err}}
    else
      {:error, :unauthorized} ->
        {content, _} =
          ContentBlocks.error_content("Not allowed", "This API key can't read runs.")

        {:ok, %{content: content, isError: true}}

      {:error, {:runner_not_found, name}} ->
        {content, _} =
          ContentBlocks.error_content(
            "No such runner",
            "No runner named `#{name}` in this account. Re-fetch /runners for current names."
          )

        {:ok, %{content: content, isError: true}}

      {:error, message} when is_binary(message) ->
        {content, _} = ContentBlocks.error_content("Invalid argument", message)
        {:ok, %{content: content, isError: true}}
    end
  end

  # `runner` / `action` filters — a non-empty string narrows; nil or "" = no
  # filter; any other type is a client bug.
  defp parse_string_arg(_label, value) when value in [nil, ""], do: {:ok, nil}
  defp parse_string_arg(_label, value) when is_binary(value), do: {:ok, value}
  defp parse_string_arg(label, _value), do: {:error, "`#{label}` must be a string."}

  # Accept a JSON number OR a numeric string (some MCP clients stringify args);
  # a non-numeric / non-positive value is rejected, not silently coerced to 20.
  defp parse_limit(n) when is_integer(n) and n > 0, do: {:ok, min(n, 100)}
  defp parse_limit(nil), do: {:ok, 20}

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, min(n, 100)}
      _ -> {:error, ~s(`limit` must be a positive integer, 1 to 100.)}
    end
  end

  defp parse_limit(_), do: {:error, ~s(`limit` must be a positive integer, 1 to 100.)}

  # Absent → the documented default "own"; a present but unrecognized value is
  # an error, never silently narrowed to "own".
  defp parse_scope(nil), do: {:ok, :own}
  defp parse_scope("own"), do: {:ok, :own}
  defp parse_scope("account"), do: {:ok, :account}
  defp parse_scope(_), do: {:error, ~s(`scope` must be "own" or "account".)}

  # -- Arg parsing ----------------------------------------------------

  # `arguments` is the flat MCP arg map: `runner` (single) or `runners`
  # (array), `reason`, an optional `wait` duration override, and the
  # action's own args. Split out the control keys from action args so
  # we don't forward them to the runner as if they were arg values.
  # Default `wait` (when omitted) is the full max_wait_ms (60s).
  defp split_call_args(args) do
    runner_names =
      cond do
        is_list(args["runners"]) -> Enum.filter(args["runners"], &is_binary/1)
        is_binary(args["runner"]) -> [args["runner"]]
        true -> []
      end

    reason = args["reason"]
    wait = args["wait"]
    attestation = normalize_attestation(args["attestation"])

    action_args =
      Map.drop(args, ["runner", "runners", "reason", "wait", "idempotency_key", "attestation"])

    {runner_names, reason, wait, attestation, action_args}
  end

  # An MCP client attaches `attestation` beside the call's runner/reason; the
  # portal RELAYS it to the runner, which verifies the Ed25519 signature. Accept
  # only a well-formed envelope (the four string fields the runner expects) so a
  # malformed one degrades to "no attestation" — an enforcing runner then refuses
  # cleanly rather than the portal forwarding junk onto the wire.
  defp normalize_attestation(%{} = att) do
    fields = Map.take(att, ["key_id", "sig", "nonce", "issued_at"])

    # Bound each field: a real attestation is small (an Ed25519 sig is 128 hex
    # chars, the nonce 32, issued_at ~25, key_id operator-chosen). 512 bytes is
    # far above any honest value but stops a leaked/abused key from fanning a
    # multi-MB blob onto every enforcing runner's PubSub topic before the runner
    # rejects the signature. An oversized/malformed envelope degrades to nil —
    # an enforcing runner then refuses cleanly.
    if map_size(fields) == 4 and
         Enum.all?(fields, fn {_k, v} -> is_binary(v) and byte_size(v) <= 512 end) do
      fields
    else
      nil
    end
  end

  defp normalize_attestation(_), do: nil

  # -- Auth -----------------------------------------------------------
  #
  # Bearer resolution (emk- static keys + emo- OAuth tokens) and the
  # RFC 9728 WWW-Authenticate challenge live in the shared `MCP.Auth`;
  # here we only shape the JSON-RPC 401 envelope.

  defp authenticate(conn, _opts) do
    case Auth.authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32001, message: "unauthorized"}})
        |> halt()
    end
  end

  defp require_scope(conn, scope) do
    key = conn.assigns.api_key

    if Enum.member?(key.scopes || [], scope) do
      :ok
    else
      {:error, -32002, "missing scope", %{required: scope}}
    end
  end

  defp app_version do
    case Application.spec(:emisar_web, :vsn) do
      nil -> "dev"
      v -> to_string(v)
    end
  end

  # MCP Streamable-HTTP session id. At `initialize` we hand the client a
  # session id (reusing one it already sent) via the Mcp-Session-Id response
  # header; the client echoes it on later requests, which we record on runs
  # + audit events for session correlation.
  defp maybe_emit_session_id(conn, "initialize") do
    session_id = req_session_id(conn) || Ecto.UUID.generate()
    put_resp_header(conn, "mcp-session-id", session_id)
  end

  defp maybe_emit_session_id(conn, _method), do: conn

  defp req_session_id(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [v | _] when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  # clientInfo is client-supplied at `initialize`. Snapshot the known
  # string fields against the authenticated key so runs dispatched after
  # can name the client. Best-effort — never affects the handshake reply.
  defp capture_client_info(conn, params) do
    key = conn.assigns[:api_key]
    info = sanitize_client_info(Map.get(params, "clientInfo"))

    if not is_nil(key) and is_map(info), do: ApiKeys.record_client_info(key, info)
    :ok
  end

  defp sanitize_client_info(%{} = info) do
    clean =
      %{
        "name" => clip_client_field(info["name"]),
        "version" => clip_client_field(info["version"]),
        "title" => clip_client_field(info["title"])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    # Only record when there's an actual name, so empty/garbage clientInfo
    # never clobbers a good prior value.
    if Map.has_key?(clean, "name"), do: clean, else: nil
  end

  defp sanitize_client_info(_), do: nil

  defp clip_client_field(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 200)
    end
  end

  defp clip_client_field(_), do: nil
end

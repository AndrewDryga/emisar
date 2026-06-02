defmodule EmisarWeb.McpRpcController do
  @moduledoc """
  MCP-over-HTTP — JSON-RPC 2.0 on a single POST endpoint at
  `/api/mcp/rpc`. The canonical MCP server implementation. Same
  Bearer-token auth as the REST routes under `/api/mcp/*`.

  ## Methods implemented

    * `initialize`        — capabilities + protocolVersion + serverInfo
    * `ping`              — `{}`
    * `tools/list`        — every action the API key can dispatch, plus
                            the synthetic `wait_for_run` tool
    * `tools/call`        — dispatch a run; result is `{content, isError}`
                            in MCP content-block shape
    * `notifications/*`   — silently dropped (per JSON-RPC notifications)

  Anything else → JSON-RPC `-32601 method not found`. Parse errors →
  `-32700`. Auth failures → JSON-RPC `-32001 unauthorized`.

  ## Stdio bridge

  `mcp/main.go` is a thin transport shim that reads stdio JSON-RPC,
  forwards the same JSON body to this endpoint, and writes the JSON-RPC
  response back to stdout. All MCP shaping (tool descriptors, content
  blocks, synthetic tools) lives in this controller + `Mcp.Service` +
  `Mcp.ContentBlocks`.
  """

  use EmisarWeb, :controller

  alias Emisar.{Accounts, ApiKeys}
  alias Emisar.Auth.Subject
  alias EmisarWeb.Mcp.{ContentBlocks, Idempotency, Service}

  @protocol_version "2024-11-05"
  @server_name "emisar"

  plug :authenticate

  # POST /api/mcp/rpc
  def handle(conn, %{"jsonrpc" => "2.0", "method" => method} = req) do
    id = Map.get(req, "id")
    params = Map.get(req, "params") || %{}

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

  defp dispatch(_conn, "initialize", _params) do
    {:ok,
     %{
       protocolVersion: @protocol_version,
       serverInfo: %{name: @server_name, version: app_version()},
       capabilities: %{tools: %{listChanged: false}}
     }}
  end

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(conn, "tools/list", _params) do
    with :ok <- require_scope(conn, "actions:read") do
      tools = Service.list_tools(conn) ++ [ContentBlocks.wait_for_run_tool()]
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
    {runner_names, reason, wait, action_args} = split_call_args(args)
    idempotency_key = Idempotency.resolve(conn, args)

    wait_ms =
      case Service.parse_wait(wait, Service.max_wait_ms()) do
        {:ok, ms} -> ms
        :error -> Service.max_wait_ms()
      end

    opts = %{
      runner_names: runner_names,
      reason: reason,
      wait_ms: wait_ms,
      idempotency_key: idempotency_key
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
        {content, _} = ContentBlocks.error_content("Runner not found", "No runner named `#{runner}` in this account.")
        {:ok, %{content: content, isError: true}}

      {:error, :runner_not_allowed, runner, why} ->
        {content, _} = ContentBlocks.error_content("Runner not allowed", "`#{runner}`: #{why}")
        {:ok, %{content: content, isError: true}}

      {:error, :no_runner_available, :unknown_action} ->
        {content, _} =
          ContentBlocks.error_content("Action not found", "No runner advertises `#{name}`.")

        {:ok, %{content: content, isError: true}}

      {:error, :no_runner_available, :scope_blocked} ->
        {content, _} =
          ContentBlocks.error_content(
            "No runner in scope",
            "`#{name}` exists but no runner you can reach is advertising it."
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

    cond do
      not is_binary(run_id) or run_id == "" ->
        {content, _} =
          ContentBlocks.error_content("Bad arguments", "wait_for_run requires `run_id` (string).")

        {:ok, %{content: content, isError: true}}

      true ->
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

    action_args = Map.drop(args, ["runner", "runners", "reason", "wait", "idempotency_key"])

    {runner_names, reason, wait, action_args}
  end

  # -- Auth -----------------------------------------------------------
  #
  # Same shape as McpController's authenticate plug so the bridge can
  # forward the user's Bearer token unchanged.

  defp authenticate(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         %{} = key <- ApiKeys.peek_api_key_by_secret(raw),
         {:ok, account} <- Accounts.fetch_account_by_id(key.account_id) do
      conn
      |> assign(:api_key, key)
      |> assign(:current_subject, Subject.for_api_key(key, account))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: -32001, message: "unauthorized"}
        })
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
end

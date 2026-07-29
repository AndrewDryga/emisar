defmodule EmisarWeb.MCPRpcController do
  @moduledoc """
  MCP-over-HTTP — JSON-RPC 2.0 on a single POST endpoint at
  `/api/mcp/rpc`. The canonical MCP server implementation.

  ## Methods implemented

    * `initialize`        — legacy handshake: capabilities + protocolVersion +
                            serverInfo (2025-11-25 / 2025-06-18 clients)
    * `server/discover`   — supported versions + capabilities (2026-07-28)
    * `ping`              — `{}` (legacy revisions)
    * `tools/list`        — the fixed tool catalog compiled from the normative
                            MCP schema registry
    * `tools/call`        — dispatch a run; result is `{content, isError}`
                            in MCP content-block shape
    * `notifications/*`   — silently dropped (per JSON-RPC notifications)

  Anything else → JSON-RPC `-32601 method not found`. Parse errors →
  `-32700`. Auth failures → JSON-RPC `-32001 unauthorized`.

  ## Streamable HTTP transport

  This is a stateless, JSON-only Streamable-HTTP **dual-era** server: POST
  handles JSON-RPC; a GET (SSE stream) and a DELETE (session termination) are
  answered `405 Method Not Allowed` — we offer neither. A request that declares
  the 2026-07-28 revision in `params._meta` is served with modern semantics
  (`resultType`, result `_meta` serverInfo, `ttlMs`/`cacheScope` on the
  catalog, strict `Mcp-Method`/`Mcp-Name` header validation → `-32020`,
  unsupported version → `-32022`, unknown method → HTTP 404); an `initialize`
  handshake selects the negotiated legacy revision, byte-identical to before.
  Transport conformance is enforced before dispatch (pure predicates live in
  `MCP.Transport`): a cross-origin browser `Origin` is `403`, a non-JSON
  `Content-Type` is `415`, an `Accept` that can't take `application/json` is
  `406`, and an unsupported `MCP-Protocol-Version` header on a post-initialize
  request is `400`.

  ## Stdio bridge

  `mcp/main.go` is a thin transport shim that reads stdio JSON-RPC,
  forwards the same JSON body to this endpoint, and writes the JSON-RPC
  response back to stdout. All MCP shaping (tool descriptors, content
  blocks, and fixed tools) lives in this controller and the `MCP.*Tools`
  modules it delegates to.
  """

  use EmisarWeb, :controller
  alias Emisar.{ApiKeys, Compat, MCPOperations}
  alias EmisarWeb.AppVersion
  alias EmisarWeb.MCP.{ActionTools, Auth, BoundaryResponse, Cancellation}
  alias EmisarWeb.MCP.{CatalogTools, RecoveryTools, RunbookTools}
  alias EmisarWeb.MCP.ClientMetadata
  alias EmisarWeb.MCP.{InputContract, Instructions, RawJSON, ResponseBudget, SchemaRegistry}
  alias EmisarWeb.MCP.Transport
  alias EmisarWeb.MCP.ValidationError

  # 2026-07-28 clients declare their version per-request in `_meta` (no
  # handshake); `initialize` negotiates only the legacy revisions.
  @modern_protocol_version "2026-07-28"
  @latest_legacy_protocol_version "2025-11-25"
  @legacy_protocol_versions [@latest_legacy_protocol_version, "2025-06-18"]
  @supported_protocol_versions [@modern_protocol_version | @legacy_protocol_versions]
  # The modern revision removed `initialize` and `ping`; a 2026-07-28 request
  # for anything outside this set is `-32601` with HTTP 404 per its transport.
  @modern_methods ~w(server/discover tools/list tools/call)
  @server_name "emisar"
  @operation_id ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/

  # A leaked key is the abuse vector — cap per key (falls back to IP for
  # unauthenticated hammering). 300/min is generous for a real LLM agent.
  plug EmisarWeb.Plugs.RateLimit,
    bucket: "mcp",
    limit: 300,
    window_ms: 60_000,
    by: :bearer,
    on_reject: {EmisarWeb.MCP.BoundaryResponse, :rate_limited}

  # Transport conformance runs before auth: an out-of-spec frame is rejected at
  # the HTTP layer regardless of the bearer. `:handle` (POST) alone negotiates a
  # body; GET/DELETE fall straight through to their 405 actions.
  plug :validate_origin
  plug :validate_content_type when action == :handle
  plug :validate_accept when action == :handle
  plug :validate_protocol_version when action == :handle
  plug :validate_exact_json when action == :handle

  plug :authenticate when action == :handle
  plug :put_client_metadata when action == :handle

  # POST /api/mcp/rpc
  def handle(conn, %{"jsonrpc" => "2.0", "method" => method} = req) when is_binary(method) do
    case envelope_kind(req) do
      {:request, id} -> handle_message(conn, :request, method, Map.get(req, "params"), id)
      :notification -> handle_message(conn, :notification, method, Map.get(req, "params"), nil)
      :invalid -> invalid_request(conn)
    end
  end

  def handle(conn, _bad_request), do: invalid_request(conn)

  defp handle_message(conn, :request, "notifications/" <> _ = method, _raw_params, id) do
    respond(conn, :request, id, {:error, -32601, "method not found", method})
  end

  defp handle_message(conn, :notification, "notifications/" <> _ = method, raw_params, _id) do
    case params_map(raw_params) do
      {:ok, params} ->
        result = Cancellation.track(conn, method, &dispatch(&1, method, params))
        respond(conn, :notification, nil, result)

      :error ->
        send_resp(conn, 202, "")
    end
  end

  defp handle_message(conn, :notification, _method, _raw_params, _id),
    do: send_resp(conn, 202, "")

  defp handle_message(conn, :request, method, raw_params, id) do
    case params_map(raw_params) do
      {:ok, params} ->
        case request_era(conn, method, params) do
          {:serve, conn} ->
            conn = maybe_acknowledge_rotation(conn)
            result = Cancellation.track(conn, method, &dispatch(&1, method, params))
            respond(conn, :request, id, decorate_result(conn, result))

          {:reject, status, code, message, data} ->
            reject_request(conn, status, id, code, message, data)
        end

      :error ->
        respond_invalid_params(conn, method, id)
    end
  end

  # -- 2026-07-28 request era -----------------------------------------
  #
  # A dual-era server selects semantics from how the request opens: modern
  # per-request `_meta` → stateless 2026-07-28 handling; an `initialize`
  # handshake → the negotiated legacy revision. Everything below rejects with
  # the modern error codes (`-32020` HeaderMismatch, `-32022`
  # UnsupportedProtocolVersion) so a probing dual-era client recognizes a
  # modern server instead of falling back to `initialize`.

  defp request_era(conn, "initialize", _params), do: {:serve, conn}

  # `server/discover` is the version probe, so it answers regardless of header
  # conformance — a stdio client relayed through the header-less bridge must be
  # able to learn our versions before deciding what to speak. Enforcement
  # applies from the first real method on.
  defp request_era(conn, "server/discover", params) do
    case Transport.meta_protocol_version(params) do
      @modern_protocol_version -> {:serve, assign(conn, :mcp_modern_request, true)}
      _version -> {:serve, conn}
    end
  end

  defp request_era(conn, method, params) do
    header_version = List.first(get_req_header(conn, "mcp-protocol-version"))

    case Transport.meta_protocol_version(params) do
      @modern_protocol_version ->
        validate_modern_request(conn, method, params, header_version)

      nil when header_version == @modern_protocol_version ->
        {:reject, :bad_request, -32_020,
         "Header mismatch: an MCP-Protocol-Version #{@modern_protocol_version} header requires the matching _meta protocol version.",
         nil}

      nil ->
        {:serve, conn}

      version when version in @legacy_protocol_versions ->
        {:serve, conn}

      version ->
        {:reject, :bad_request, -32_022, "Unsupported protocol version",
         %{supported: @supported_protocol_versions, requested: version}}
    end
  end

  defp validate_modern_request(conn, method, params, header_version) do
    cond do
      header_version != @modern_protocol_version ->
        {:reject, :bad_request, -32_020,
         "Header mismatch: the MCP-Protocol-Version header must be present and match the _meta protocol version.",
         nil}

      List.first(get_req_header(conn, "mcp-method")) != method ->
        {:reject, :bad_request, -32_020,
         "Header mismatch: the Mcp-Method header must be present and match the request method.",
         nil}

      method == "tools/call" and
          not Transport.mcp_name_matches?(get_req_header(conn, "mcp-name"), params["name"]) ->
        {:reject, :bad_request, -32_020,
         "Header mismatch: the Mcp-Name header must be present and match params.name on tools/call.",
         nil}

      method not in @modern_methods ->
        {:reject, :not_found, -32_601, "method not found", method}

      true ->
        {:serve, assign(conn, :mcp_modern_request, true)}
    end
  end

  defp reject_request(conn, status, id, code, message, data) do
    error = %{code: code, message: message}
    error = if data, do: Map.put(error, :data, data), else: error

    conn
    |> put_status(status)
    |> json(%{jsonrpc: "2.0", id: id, error: error})
  end

  # Modern results carry the fields the 2026-07-28 revision requires on every
  # result; legacy results stay byte-identical.
  defp decorate_result(%{assigns: %{mcp_modern_request: true}}, {:ok, result}) do
    {:ok,
     result
     |> Map.put(:resultType, "complete")
     |> Map.put(:_meta, %{"io.modelcontextprotocol/serverInfo" => server_info()})}
  end

  defp decorate_result(_conn, result), do: result

  defp respond(conn, :notification, _id, _result), do: send_resp(conn, 202, "")
  defp respond(conn, :request, _id, :cancelled), do: send_resp(conn, 204, "")
  defp respond(conn, :request, _id, :no_reply), do: send_resp(conn, 204, "")

  defp respond(conn, :request, id, {:ok, result}) do
    send_bounded_frame(conn, %{jsonrpc: "2.0", id: id, result: result}, result)
  end

  defp respond(conn, :request, id, {:error, code, message}) do
    send_bounded_frame(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  defp respond(conn, :request, id, {:error, code, message, data}) do
    send_bounded_frame(conn, %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: code, message: message, data: data}
    })
  end

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: "invalid request"}})
  end

  defp envelope_kind(req) do
    if Map.has_key?(req, "id") do
      case req["id"] do
        id when is_binary(id) or is_integer(id) ->
          if ResponseBudget.valid_request_id?(id), do: {:request, id}, else: :invalid

        _invalid_id ->
          :invalid
      end
    else
      :notification
    end
  end

  # GET /api/mcp/rpc — a Streamable-HTTP client opens an SSE stream here; this
  # stateless server offers none, so the spec's answer is 405.
  def reject_stream(conn, _params), do: method_not_allowed(conn)

  # DELETE /api/mcp/rpc — session termination; this stateless server issues no
  # durable session to terminate, so 405 per the spec.
  def reject_termination(conn, _params), do: method_not_allowed(conn)

  defp method_not_allowed(conn) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(:method_not_allowed)
    |> json(%{
      error:
        "The MCP endpoint only accepts POST — this stateless server offers no SSE stream (GET) or session termination (DELETE)."
    })
  end

  defp validate_exact_json(%{assigns: %{raw_body: raw_body}} = conn, _opts) do
    case RawJSON.parse(raw_body) do
      {:ok, tree} ->
        assign(conn, :mcp_json_tree, tree)

      {:error, _reason} ->
        BoundaryResponse.send_error(conn, :bad_request, -32_700, "Parse error",
          inspect_body: false
        )
    end
  end

  defp validate_exact_json(conn, _opts) do
    BoundaryResponse.send_error(conn, :bad_request, -32_700, "Parse error", inspect_body: false)
  end

  # -- Method dispatch ------------------------------------------------

  defp dispatch(conn, "initialize", params) do
    capture_client_info(conn, params)

    with :ok <- enforce_bridge_version(conn) do
      {:ok,
       %{
         protocolVersion: negotiated_protocol_version(params),
         serverInfo: server_info(),
         capabilities: capabilities(),
         instructions: Instructions.text()
       }}
    end
  end

  # 2026-07-28 discovery — the modern replacement for `initialize`: same
  # identity/capability payload, plus the version list a client picks from.
  # Like `initialize` it is not gated on key kind; it reveals nothing a key
  # holder couldn't learn from the handshake.
  defp dispatch(conn, "server/discover", _params) do
    {:ok,
     put_catalog_cache_fields(conn, %{
       supportedVersions: @supported_protocol_versions,
       capabilities: capabilities(),
       instructions: Instructions.text()
     })}
  end

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(conn, "tools/list", _params) do
    with :ok <- require_mcp_key(conn) do
      {:ok, put_catalog_cache_fields(conn, %{tools: SchemaRegistry.tools()})}
    end
  end

  defp dispatch(conn, "tools/call", params) do
    name = Map.get(params, "name", "")
    args = Map.get(params, "arguments", %{})

    cond do
      name == "" ->
        invalid_tool_call(conn, name, "missing tool name",
          issues: [ValidationError.issue([:name], :required)]
        )

      not is_binary(name) ->
        invalid_tool_call(conn, name, "tool name must be a string",
          issues: [ValidationError.issue([:name], :type)]
        )

      name in SchemaRegistry.tool_names() ->
        with :ok <- require_mcp_key(conn) do
          case validate_tool_input(conn, name, args) do
            {:ok, validated_args} -> dispatch_tool(conn, name, validated_args)
            {:invalid, result} -> result
          end
        end

      true ->
        :ok = ValidationError.log_unknown_tool(conn, name)

        fixed_tool_result(
          conn,
          name,
          %{
            ok: false,
            error: %{
              code: "unknown_tool",
              message:
                "Unknown tool. Emisar exposes only its twelve fixed API tools; an action id like 'postgres.restart' is not a tool. Discover with find_actions/get_action, then dispatch via run_action.",
              retryable: false
            },
            dispatch_started: false
          },
          true
        )
    end
  end

  defp dispatch(conn, "notifications/cancelled", _params) do
    :ok = Cancellation.cancel(conn)
    :no_reply
  end

  defp dispatch(_conn, "notifications/" <> _, _params), do: :no_reply

  defp dispatch(_conn, method, _params),
    do: {:error, -32601, "method not found", method}

  defp dispatch_tool(conn, "run_action", args), do: handle_run_action(conn, args)

  defp dispatch_tool(conn, name, args)
       when name in ~w(list_packs list_runners find_actions get_action),
       do: handle_catalog_tool(conn, name, args)

  defp dispatch_tool(conn, name, args)
       when name in ~w(list_runbooks get_runbook execute_runbook create_runbook_draft),
       do: handle_runbook_tool(conn, name, args)

  defp dispatch_tool(conn, name, args)
       when name in ~w(get_operation wait_for_run recent_runs),
       do: handle_recovery_tool(conn, name, args)

  defp validate_tool_input(conn, name, args) do
    case InputContract.validate(name, args) do
      {:ok, validated_args} ->
        {:ok, validated_args}

      {:error, issues} ->
        {:invalid,
         fixed_tool_result(
           conn,
           name,
           ValidationError.payload("Tool arguments do not match the published input schema.",
             stage: :arguments,
             issues: issues
           ),
           true
         )}
    end
  end

  defp params_map(nil), do: {:ok, %{}}
  defp params_map(%{} = params), do: {:ok, params}
  defp params_map(_), do: :error

  # -- Tool call ------------------------------------------------------

  defp handle_catalog_tool(conn, name, args) do
    case CatalogTools.call(conn, name, args) do
      {:ok, payload} -> fixed_tool_result(conn, name, payload, false)
      {:error, payload} -> fixed_tool_result(conn, name, payload, true)
    end
  end

  defp fixed_tool_result(conn, tool, payload, is_error) do
    :ok = ValidationError.log(conn, tool, payload)
    {:ok, ResponseBudget.fixed_result(payload, is_error)}
  end

  defp invalid_tool_call(conn, tool, message, opts) do
    details = ValidationError.details(Keyword.put(opts, :stage, :tool_call))
    :ok = ValidationError.log_details(conn, tool, details)
    {:error, -32602, message, details}
  end

  defp respond_invalid_params(conn, "tools/call", id) do
    result =
      invalid_tool_call(conn, "unknown", "params must be an object",
        issues: [ValidationError.issue([], :type)]
      )

    respond(conn, :request, id, result)
  end

  defp respond_invalid_params(conn, _method, id) do
    json(conn, %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32602, message: "params must be an object"}
    })
  end

  defp send_bounded_frame(conn, frame, result \\ nil) do
    case ResponseBudget.encode_frame(frame) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :response_too_large} ->
        send_response_too_large(conn, frame.id, result)
    end
  end

  defp send_response_too_large(conn, id, result) do
    data = response_recovery_data(result)

    frame = %{
      jsonrpc: "2.0",
      id: id,
      error: %{
        code: -32_603,
        message: "Response exceeds the MCP transport limit; retry reads with a lower limit.",
        data: data
      }
    }

    {:ok, body} = ResponseBudget.encode_frame(frame)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  defp response_recovery_data(%{structuredContent: %{operation_id: operation_id}})
       when is_binary(operation_id) do
    %{
      operation_id: operation_id,
      next: %{tool: "get_operation", arguments: %{operation_id: operation_id}}
    }
  end

  defp response_recovery_data(_result), do: %{}

  defp handle_run_action(conn, args) do
    case RawJSON.tool_call(conn.assigns.raw_body) do
      {:ok, %{name: "run_action", action_args: args_raw}} ->
        dispatch_run_action(conn, args, args_raw)

      _ ->
        fixed_tool_result(
          conn,
          "run_action",
          ValidationError.payload("run_action arguments are malformed.",
            stage: :tool_call,
            issues: [ValidationError.issue([:arguments], :schema)]
          ),
          true
        )
    end
  end

  defp dispatch_run_action(conn, args, args_raw) do
    case mutation_operation_id(conn) do
      operation_id when is_binary(operation_id) ->
        case ActionTools.call(
               conn,
               args,
               args_raw,
               operation_id,
               get_req_header(conn, "emisar-attestation")
             ) do
          {:ok, payload} -> fixed_tool_result(conn, "run_action", payload, false)
          {:error, payload} -> fixed_tool_result(conn, "run_action", payload, true)
          :cancelled -> :cancelled
        end

      _ ->
        fixed_tool_result(
          conn,
          "run_action",
          %{
            ok: false,
            error: %{
              code: "invalid_operation",
              message:
                "This mutation requires one transport-owned operation_id. This is a bridge or transport fault; report it to the operator instead of changing valid arguments.",
              retryable: false
            },
            dispatch_started: false
          },
          true
        )
    end
  end

  defp handle_runbook_tool(conn, name, args)
       when name in ~w(execute_runbook create_runbook_draft) do
    case mutation_operation_id(conn) do
      operation_id when is_binary(operation_id) ->
        runbook_tool_result(conn, name, args, operation_id)

      _ ->
        fixed_tool_result(
          conn,
          name,
          %{
            ok: false,
            error: %{
              code: "invalid_operation",
              message:
                "This mutation requires one transport-owned operation_id. If your args match the schema, this is a bridge/transport fault, not an argument error — report it to the operator; do not re-edit valid args or retry in a loop.",
              retryable: false
            },
            dispatch_started: false
          },
          true
        )
    end
  end

  defp handle_runbook_tool(conn, name, args), do: runbook_tool_result(conn, name, args, nil)

  defp runbook_tool_result(conn, name, args, operation_id) do
    case RunbookTools.call(conn, name, args, operation_id) do
      {:ok, payload} -> fixed_tool_result(conn, name, payload, false)
      {:error, payload} -> fixed_tool_result(conn, name, payload, true)
    end
  end

  defp mutation_operation_id(conn) do
    case get_req_header(conn, "emisar-operation-id") do
      [operation_id] when is_binary(operation_id) ->
        if Regex.match?(@operation_id, operation_id), do: operation_id

      [] ->
        MCPOperations.operation_id(conn.assigns.raw_body, conn.assigns.current_subject)

      _multiple ->
        nil
    end
  end

  defp handle_recovery_tool(conn, name, args) do
    case RecoveryTools.call(conn, name, args) do
      {:ok, payload} -> fixed_tool_result(conn, name, payload, false)
      {:error, payload} -> fixed_tool_result(conn, name, payload, true)
      :cancelled -> :cancelled
    end
  end

  # -- Streamable HTTP transport --------------------------------------
  #
  # HTTP-layer conformance (pure decisions in `MCP.Transport`). Each rejection
  # halts with the spec-correct status and a small JSON body so an MCP client
  # sees a clear reason rather than a framework error page.

  defp validate_origin(conn, _opts) do
    if Transport.allowed_origin?(get_req_header(conn, "origin"), EmisarWeb.Endpoint.url()) do
      conn
    else
      reject(conn, :forbidden, "Cross-origin request rejected.")
    end
  end

  defp validate_content_type(conn, _opts) do
    if Transport.json_content_type?(get_req_header(conn, "content-type")) do
      conn
    else
      reject(conn, :unsupported_media_type, "Content-Type must be application/json.")
    end
  end

  defp validate_accept(conn, _opts) do
    if Transport.accepts_json?(get_req_header(conn, "accept")) do
      conn
    else
      reject(
        conn,
        :not_acceptable,
        "This endpoint returns application/json; the Accept header must allow it."
      )
    end
  end

  # The `initialize` request negotiates the protocol version in its body, so its
  # header isn't validated; every later request carrying an unsupported header is
  # 400 per the spec. The rejection is the modern `-32022`
  # UnsupportedProtocolVersionError naming the supported set, so a client on a
  # future revision retries with one of ours instead of treating us as legacy.
  defp validate_protocol_version(conn, _opts) do
    cond do
      conn.body_params["method"] == "initialize" ->
        conn

      Transport.acceptable_protocol_version?(
        get_req_header(conn, "mcp-protocol-version"),
        @supported_protocol_versions
      ) ->
        conn

      true ->
        requested = List.first(get_req_header(conn, "mcp-protocol-version"))

        BoundaryResponse.send_error(
          conn,
          :bad_request,
          -32_022,
          "Unsupported MCP-Protocol-Version header.",
          data: %{supported: @supported_protocol_versions, requested: requested}
        )
    end
  end

  defp reject(conn, status, message) do
    BoundaryResponse.send_error(conn, status, -32_600, message)
  end

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
        BoundaryResponse.send_error(conn, :unauthorized, -32_001, "unauthorized")
    end
  end

  # Self-reported MCP client metadata (Emisar-Client-Metadata header): validated
  # here, then stamped onto the authenticated subject's request context so the
  # dispatch snapshots it onto the run for audit/SIEM correlation. Untrusted
  # enrichment — malformed input fails the request closed (never a partial
  # snapshot); it is never an authorization/policy/approval input.
  defp put_client_metadata(conn, _opts) do
    case ClientMetadata.parse(get_req_header(conn, "emisar-client-metadata")) do
      {:ok, metadata} ->
        subject = conn.assigns.current_subject
        context = %{subject.context | mcp_client_metadata: metadata}
        assign(conn, :current_subject, %{subject | context: context})

      {:error, message} ->
        BoundaryResponse.send_error(conn, :ok, -32_602, message)
    end
  end

  # The MCP tool surface is for `:mcp` keys only — an audit-export token
  # authenticates but has no tool business. Downstream, account Policy +
  # approval + the operator's runner scope decide what an MCP key may do; the
  # key carries no per-key grant.
  defp require_mcp_key(conn) do
    if conn.assigns.api_key.kind == :mcp do
      :ok
    else
      {:error, -32002, "wrong key kind", %{required: "mcp"}}
    end
  end

  # `initialize` selects legacy semantics by definition (the modern revision
  # has no handshake), so it only ever negotiates a legacy revision — a client
  # requesting anything else is offered the latest legacy version, per the
  # legacy lifecycle's "respond with another supported version" rule.
  defp negotiated_protocol_version(%{"protocolVersion" => requested})
       when requested in @legacy_protocol_versions,
       do: requested

  defp negotiated_protocol_version(_params), do: @latest_legacy_protocol_version

  defp server_info, do: %{name: @server_name, version: AppVersion.version()}

  defp capabilities, do: %{tools: %{listChanged: false}}

  # `tools/list` and `server/discover` are CacheableResults on 2026-07-28. The
  # catalog is fixed per deploy, so an hour's client-side cache is safe;
  # "private" because the results ride authenticated, account-scoped requests
  # no shared intermediary may cache.
  defp put_catalog_cache_fields(%{assigns: %{mcp_modern_request: true}}, result),
    do: Map.merge(result, %{ttlMs: 3_600_000, cacheScope: "private"})

  defp put_catalog_cache_fields(_conn, result), do: result

  # The bridge persists a client-generated successor before proposing it on an
  # authenticated request. The portal installs those exact non-secret values
  # idempotently and acknowledges the digest; retrying on ordinary requests lets
  # a long-lived bridge cross into the rotation window without reconnecting.
  defp maybe_acknowledge_rotation(conn) do
    with true <- bridge_client?(conn),
         {:ok, prefix, hash} <- rotation_proposal(conn),
         {:ok, _successor} <-
           ApiKeys.install_auto_rotation_successor(
             prefix,
             hash,
             conn.assigns.current_subject
           ) do
      put_resp_header(conn, "x-emisar-rotation-ack", Base.encode16(hash, case: :lower))
    else
      _ -> conn
    end
  end

  defp rotation_proposal(conn) do
    case {
      get_req_header(conn, "x-emisar-rotation-prefix"),
      get_req_header(conn, "x-emisar-rotation-hash")
    } do
      {[prefix], [encoded_hash]} when byte_size(prefix) == 12 and byte_size(encoded_hash) == 64 ->
        with {:ok, hash} <- Base.decode16(encoded_hash, case: :mixed),
             true <- byte_size(hash) == 32 do
          {:ok, prefix, hash}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp bridge_client?(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> String.starts_with?(ua, "emisar-mcp/")
      [] -> false
    end
  end

  # The stdio bridge stamps `emisar-mcp/<version>` in the User-Agent; extract
  # the version so the compatibility policy can judge it. A remote connector
  # (no bridge) has no such UA → nil → :unknown, which is never blocked.
  defp bridge_version(conn) do
    case get_req_header(conn, "user-agent") do
      ["emisar-mcp/" <> rest | _] ->
        rest |> String.split() |> List.first()

      _ ->
        nil
    end
  end

  # Refuse a below-minimum emisar-mcp bridge at `initialize` when enforcement
  # is on — a structured JSON-RPC error naming the minimum + upgrade path, so
  # the operator's LLM surfaces a clear reason rather than a cryptic failure.
  # Warn-only mode (and :unknown/:outdated/:supported) hands back :ok.
  defp enforce_bridge_version(conn) do
    version = bridge_version(conn)

    if Compat.enforce_mcp?() and Compat.mcp_status(version) == :unsupported do
      {:error, -32003, "emisar-mcp bridge version unsupported",
       %{
         minimum: Compat.mcp_minimum(),
         your_version: version,
         upgrade: "Update the emisar-mcp bridge: https://emisar.dev/docs/connect-a-cli-client"
       }}
    else
      :ok
    end
  end

  # clientInfo is client-supplied at `initialize`. Snapshot the known
  # string fields against the authenticated key so runs dispatched after
  # can name the client. Best-effort — never affects the handshake reply.
  defp capture_client_info(conn, params) do
    key = conn.assigns[:api_key]
    info = client_info_snapshot(conn, params)

    if not is_nil(key) and is_map(info), do: ApiKeys.record_client_info(key, info)
    :ok
  end

  # The connecting client's identity — its clientInfo, plus the emisar-mcp
  # bridge version from the UA (which the console warns on when stale). Only
  # recorded when clientInfo carries a name, so garbage never clobbers a good
  # prior value.
  defp client_info_snapshot(conn, params) do
    case sanitize_client_info(Map.get(params, "clientInfo")) do
      nil -> nil
      info -> put_bridge_version(info, ValidationError.safe_version(bridge_version(conn)))
    end
  end

  defp put_bridge_version(info, nil), do: info
  defp put_bridge_version(info, version), do: Map.put(info, "bridge_version", version)

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

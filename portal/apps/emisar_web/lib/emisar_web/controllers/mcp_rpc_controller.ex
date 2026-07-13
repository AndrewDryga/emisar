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
                            `get_runbook`, `execute_runbook`,
                            `create_runbook_draft`, and `recent_runs` tools
    * `tools/call`        — dispatch a run; result is `{content, isError}`
                            in MCP content-block shape
    * `notifications/*`   — silently dropped (per JSON-RPC notifications)

  Anything else → JSON-RPC `-32601 method not found`. Parse errors →
  `-32700`. Auth failures → JSON-RPC `-32001 unauthorized`.

  ## Streamable HTTP transport

  This is a stateless, JSON-only Streamable-HTTP (2025-06-18) server: POST
  handles JSON-RPC; a GET (SSE stream) and a DELETE (session termination) are
  answered `405 Method Not Allowed` — we offer neither. Transport conformance is
  enforced before dispatch (pure predicates live in `MCP.Transport`): a
  cross-origin browser `Origin` is `403`, a non-JSON `Content-Type` is `415`, an
  `Accept` that can't take `application/json` is `406`, and an unsupported
  `MCP-Protocol-Version` header on a post-initialize request is `400`.

  ## Stdio bridge

  `mcp/main.go` is a thin transport shim that reads stdio JSON-RPC,
  forwards the same JSON body to this endpoint, and writes the JSON-RPC
  response back to stdout. All MCP shaping (tool descriptors, content
  blocks, synthetic tools) lives in this controller + `MCP.Service` +
  `MCP.ContentBlocks`.
  """

  use EmisarWeb, :controller
  alias Emisar.{ApiKeys, Compat}
  alias EmisarWeb.MCP.{Attestation, Auth, ClientMetadata, ContentBlocks}
  alias EmisarWeb.MCP.{Idempotency, Instructions, Service, Transport}
  alias EmisarWeb.RequestContext

  @latest_protocol_version "2025-06-18"
  @supported_protocol_versions [@latest_protocol_version, "2024-11-05"]
  @server_name "emisar"

  # A leaked key is the abuse vector — cap per key (falls back to IP for
  # unauthenticated hammering). 300/min is generous for a real LLM agent.
  plug EmisarWeb.Plugs.RateLimit, bucket: "mcp", limit: 300, window_ms: 60_000, by: :bearer

  # Transport conformance runs before auth: an out-of-spec frame is rejected at
  # the HTTP layer regardless of the bearer. `:handle` (POST) alone negotiates a
  # body; GET/DELETE fall straight through to their 405 actions.
  plug :validate_origin
  plug :validate_content_type when action == :handle
  plug :validate_accept when action == :handle
  plug :validate_protocol_version when action == :handle

  plug :authenticate when action == :handle
  plug :put_client_metadata when action == :handle

  # POST /api/mcp/rpc
  def handle(conn, %{"jsonrpc" => "2.0", "method" => method} = req) when is_binary(method) do
    id = Map.get(req, "id")

    case params_map(Map.get(req, "params")) do
      {:ok, params} ->
        conn = conn |> maybe_emit_session_id(method) |> maybe_offer_successor(method)

        case dispatch(conn, method, params) do
          :no_reply ->
            # JSON-RPC notification — RFC says no response body.
            send_resp(conn, 202, "")

          {:ok, result} ->
            json(conn, %{jsonrpc: "2.0", id: id, result: result})

          {:error, code, message} ->
            json(conn, %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})

          {:error, code, message, data} ->
            json(conn, %{
              jsonrpc: "2.0",
              id: id,
              error: %{code: code, message: message, data: data}
            })
        end

      :error ->
        json(conn, %{
          jsonrpc: "2.0",
          id: id,
          error: %{code: -32602, message: "params must be an object"}
        })
    end
  end

  def handle(conn, _bad_request) do
    conn
    |> put_status(:bad_request)
    |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: "invalid request"}})
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

  # -- Method dispatch ------------------------------------------------

  defp dispatch(conn, "initialize", params) do
    capture_client_info(conn, params)

    with :ok <- enforce_bridge_version(conn) do
      {:ok,
       %{
         protocolVersion: negotiated_protocol_version(params),
         serverInfo: %{name: @server_name, version: app_version()},
         capabilities: %{tools: %{listChanged: false}},
         instructions: Instructions.text()
       }}
    end
  end

  defp dispatch(_conn, "ping", _params), do: {:ok, %{}}

  defp dispatch(conn, "tools/list", _params) do
    with :ok <- require_mcp_key(conn) do
      tools =
        Service.list_tools(conn) ++
          [
            ContentBlocks.wait_for_run_tool(),
            ContentBlocks.list_runbooks_tool(),
            ContentBlocks.get_runbook_tool(),
            ContentBlocks.execute_runbook_tool(),
            ContentBlocks.create_runbook_draft_tool(),
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

      not is_binary(name) ->
        {:error, -32602, "tool name must be a string"}

      not is_map(args) ->
        {:error, -32602, "tool arguments must be an object"}

      name == "wait_for_run" ->
        with :ok <- require_mcp_key(conn) do
          handle_wait_for_run(conn, args)
        end

      name == "list_runbooks" ->
        with :ok <- require_mcp_key(conn) do
          handle_list_runbooks(conn)
        end

      name == "get_runbook" ->
        with :ok <- require_mcp_key(conn) do
          handle_get_runbook(conn, args)
        end

      name == "execute_runbook" ->
        with :ok <- require_mcp_key(conn) do
          handle_execute_runbook(conn, args)
        end

      name == "create_runbook_draft" ->
        with :ok <- require_mcp_key(conn) do
          handle_create_runbook_draft(conn, args)
        end

      name == "recent_runs" ->
        with :ok <- require_mcp_key(conn) do
          handle_recent_runs(conn, args)
        end

      true ->
        with :ok <- require_mcp_key(conn) do
          handle_tool_call(conn, name, args)
        end
    end
  end

  defp dispatch(_conn, "notifications/" <> _, _params), do: :no_reply

  defp dispatch(_conn, method, _params),
    do: {:error, -32601, "method not found", method}

  defp params_map(nil), do: {:ok, %{}}
  defp params_map(%{} = params), do: {:ok, params}
  defp params_map(_), do: :error

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

      {:error, :reason_required} ->
        {content, _} =
          ContentBlocks.error_content(
            "Reason required",
            "Every action call must include a non-empty `reason` — a short sentence on why. " <>
              "It lands in the audit log so an operator can later answer 'why did this fire?'."
          )

        {:ok, %{content: content, isError: true}}

      {:error, :runner_required, candidates} ->
        msg =
          "This action needs an explicit target — emisar never auto-picks a runner, even " <>
            "when only one advertises it. Retry with `runners: [\"name\"]`, choosing from " <>
            "the candidates: " <> Enum.join(candidates, ", ")

        {content, _} = ContentBlocks.error_content("Runner required", msg)
        {:ok, %{content: content, isError: true}}

      {:error, :invalid_runner_targets} ->
        {content, _} =
          ContentBlocks.error_content(
            "Invalid runner targets",
            "`runners` must be an array of runner-name strings."
          )

        {:ok, %{content: content, isError: true}}

      {:error, :duplicate_runners} ->
        {content, _} =
          ContentBlocks.error_content(
            "Duplicate runners",
            "Each runner may be targeted at most once per action call."
          )

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
    timeout = Map.get(args, "timeout", "5m")

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
              "Expected a duration like \"60s\" or \"5m\" (max 5m)."
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

  # -- Runbooks (execute + draft) -------------------------------------

  defp handle_execute_runbook(conn, args) do
    reason = Map.get(args, "reason")
    idempotency_key = Idempotency.resolve(conn, args)

    case Map.get(args, "runbook") do
      slug when is_binary(slug) and slug != "" ->
        run_execute_runbook(conn, slug, reason, idempotency_key)

      _ ->
        tool_error(
          "Bad arguments",
          "execute_runbook requires `runbook` (a published runbook's slug or id string)."
        )
    end
  end

  defp run_execute_runbook(conn, slug, reason, idempotency_key) do
    case Service.execute_runbook(conn, slug, reason, idempotency_key) do
      {:ok, payload} ->
        {content, is_err} = ContentBlocks.from_runbook_execution(payload)
        {:ok, %{content: content, isError: is_err}}

      {:error, :reason_required} ->
        tool_error(
          "Reason required",
          "execute_runbook needs a non-empty `reason` — a short sentence on why. It's logged " <>
            "in the audit trail and carried onto every step's run."
        )

      {:error, :not_found} ->
        tool_error(
          "Runbook not found",
          "No PUBLISHED runbook with slug or id `#{slug}`. Call list_runbooks to see what can " <>
            "be executed; drafts can't be run until an operator publishes them."
        )

      {:error, :unauthorized} ->
        tool_error("Not allowed", "This API key can't execute runbooks.")

      {:error, :empty_runbook} ->
        tool_error(
          "Runbook has no steps",
          "This runbook has no steps to run — nothing was dispatched."
        )

      {:error, {:step_no_runners, n}} ->
        tool_error(
          "Step has no runners",
          "Step #{n}'s target group resolves to no currently-connected runners. Bring a matching " <>
            "runner online (Runners page) or fix the step's target, then retry."
        )

      {:error, {:fan_out_too_large, max}} ->
        tool_error(
          "Runbook too large",
          "This runbook resolves to more than #{max} step-runs. Split it into smaller runbooks."
        )

      {:error, :duplicate_step_ids} ->
        tool_error(
          "Duplicate step ids",
          "Two steps share an id, which would collide on dispatch. An operator must fix the " <>
            "runbook so every step has a unique id."
        )

      {:error, _other} ->
        tool_error(
          "Execution failed",
          "The runbook could not be started. If this persists, surface it to the operator — it " <>
            "usually maps to an admin-side fix (policy, runner scope, or pack trust)."
        )
    end
  end

  defp handle_create_runbook_draft(conn, args) do
    with {:ok, title} <- require_string_arg("title", Map.get(args, "title")),
         {:ok, steps} <- validate_steps(Map.get(args, "steps")) do
      params = %{
        "title" => title,
        "slug" => Map.get(args, "slug"),
        "description" => Map.get(args, "description"),
        "steps" => steps
      }

      case Service.create_runbook_draft(conn, params) do
        {:ok, payload} ->
          {content, is_err} = ContentBlocks.from_runbook_draft(payload)
          {:ok, %{content: content, isError: is_err}}

        {:error, %Ecto.Changeset{} = changeset} ->
          tool_error(
            "Invalid runbook",
            "The draft failed validation:\n" <> changeset_error_lines(changeset)
          )

        {:error, :unauthorized} ->
          tool_error("Not allowed", "This API key can't create runbook drafts.")
      end
    else
      {:error, message} -> tool_error("Bad arguments", message)
    end
  end

  defp require_string_arg(_label, value) when is_binary(value) and value != "", do: {:ok, value}
  defp require_string_arg(label, _value), do: {:error, "`#{label}` is required (a string)."}

  # Steps come from an LLM — accept an array (of step objects) or reject clearly.
  # The changeset does the real bounds/shape validation on save.
  defp validate_steps(steps) when is_list(steps), do: {:ok, steps}
  defp validate_steps(nil), do: {:error, "`steps` is required (an array of step objects)."}
  defp validate_steps(_), do: {:error, "`steps` must be an array of step objects."}

  defp changeset_error_lines(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("\n", fn {field, msgs} -> "- #{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp tool_error(header, body) do
    {content, _} = ContentBlocks.error_content(header, body)
    {:ok, %{content: content, isError: true}}
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
        Map.has_key?(args, "runners") -> args["runners"]
        Map.has_key?(args, "runner") -> [args["runner"]]
        true -> []
      end

    reason = args["reason"]
    wait = args["wait"]
    attestation = Attestation.normalize(args["attestation"])

    action_args =
      Map.drop(args, ["runner", "runners", "reason", "wait", "idempotency_key", "attestation"])

    {runner_names, reason, wait, attestation, action_args}
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
  # 400 per the spec.
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
        reject(conn, :bad_request, "Unsupported MCP-Protocol-Version header.")
    end
  end

  defp reject(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
    |> halt()
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
        conn
        |> put_status(:unauthorized)
        |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32001, message: "unauthorized"}})
        |> halt()
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
        conn
        |> json(%{jsonrpc: "2.0", id: nil, error: %{code: -32602, message: message}})
        |> halt()
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

  defp app_version do
    case Application.spec(:emisar_web, :vsn) do
      nil -> "dev"
      v -> to_string(v)
    end
  end

  defp negotiated_protocol_version(%{"protocolVersion" => requested})
       when requested in @supported_protocol_versions,
       do: requested

  defp negotiated_protocol_version(_params), do: @latest_protocol_version

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
    RequestContext.mcp_session_id(conn)
  end

  # Response-carried key rotation for the stdio bridge: when the caller's key
  # is expiring soon, `initialize`'s response carries a freshly-minted
  # successor in HEADERS only — never the JSON-RPC body, which the bridge
  # forwards verbatim into the LLM transcript. Gated on the bridge's
  # User-Agent so the at-most-once successor isn't burned on a remote
  # connector that ignores response headers (same-trust gate: the bearer
  # holder is the recipient either way).
  defp maybe_offer_successor(conn, "initialize") do
    with true <- bridge_client?(conn),
         {:ok, raw, successor} <- ApiKeys.auto_rotate_expiring(conn.assigns.current_subject) do
      conn
      |> put_resp_header("x-emisar-successor-key", raw)
      |> put_resp_header(
        "x-emisar-successor-expires-at",
        DateTime.to_iso8601(successor.expires_at)
      )
    else
      _ -> conn
    end
  end

  defp maybe_offer_successor(conn, _method), do: conn

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
      ["emisar-mcp/" <> rest | _] -> rest |> String.split() |> List.first()
      _ -> nil
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
         upgrade: "Update the emisar-mcp bridge: https://emisar.dev/docs/connect-an-llm"
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
      info -> put_bridge_version(info, bridge_version(conn))
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

defmodule EmisarWeb.MCPController do
  @moduledoc """
  MCP / LLM tool surface. Authenticates via API key in the
  `Authorization: Bearer <key>` header.

  Endpoints:

    * `GET  /api/mcp/runners` — list the runners this key may dispatch
      to, with their metadata and advertised action ids. LLMs use this
      for discovery: "I want to operate on the primary cassandra node →
      look up the runner name, pass it as `runner` in the tool call."

    * `GET  /api/mcp/tools` — return MCP-shaped tool descriptors. One
      entry per distinct action_id. Each tool's input schema declares a
      required `runners` array whose enum lists the runners advertising
      it — always required, even when only one advertises, so the call
      names its target host explicitly (emisar never auto-picks).

    * `POST /api/mcp/tools/:action_id` — dispatch a run. Body is flat:

          {"runners": ["db-prod-01"], "reason": "...", ...action args}

      Defaults to fire-and-forget; add `?wait=15s` (max 60s) to long-poll
      for the result inline.

    * `GET  /api/mcp/runs/:id` — fetch run state with stdout / stderr.

  Every endpoint scopes by `api_key.account_id` AND respects the MINTING
  OPERATOR's runner scope (`UserRunnerScope`): runners the operator has no
  grant for are invisible in /runners, omitted from the runner enums in
  /tools, and rejected on dispatch. The key carries no per-key scope of its own.

  All business logic — runner resolution, dispatch, long-poll, payload
  building — lives in `EmisarWeb.MCP.Service`, shared with the JSON-RPC
  controller. This controller only authenticates, shapes HTTP params into
  the args Service expects, and renders the REST HTTP envelope (status
  codes + JSON shape).
  """

  use EmisarWeb, :controller
  alias EmisarWeb.MCP.{Auth, Idempotency, Service}

  # A leaked key is the abuse vector — cap per key (falls back to IP for
  # unauthenticated hammering). 300/min is generous for a real LLM agent.
  plug EmisarWeb.Plugs.RateLimit, bucket: "mcp", limit: 300, window_ms: 60_000, by: :bearer

  plug :authenticate
  plug :require_mcp_key

  # GET /api/mcp/runners
  def list_runners(conn, _params) do
    json(conn, %{runners: Service.list_runners(conn)})
  end

  # GET /api/mcp/tools
  def list_tools(conn, _params) do
    json(conn, %{tools: Service.list_tools(conn)})
  end

  # POST /api/mcp/tools/:action_id
  #
  # Body shape (flat):
  #   {"runners": ["runner-1", "runner-2"], "reason": "...", ...action args}
  #
  # Returns `{runs: [{runner, run_id, status, ...}, ...]}` — always an
  # array, one element per dispatched runner, in input order. Per-run
  # status drives whether the LLM should call `wait_for_run` next on
  # each id (pending_approval / running) or treat it as final (success,
  # denied, etc.).
  def run_tool(conn, %{"action_id" => action_id} = params) do
    # Anything the LLM passes beyond the known top-level keys is an
    # action arg. `wait` is a query param but Phoenix merges query +
    # body into params, so it may land here too. `idempotency_key` is a
    # control fields (Layer 2 idempotency and runner attestation), not action
    # args — drop them so they never reach the runner as action input.
    #
    # These are reserved arg names: `emisar pack validate` rejects any
    # action arg sharing one (runner pkg/actionspec reservedArgNames), so
    # a real action arg can never be silently stripped here. Keep the two
    # lists in sync.
    action_args =
      Map.drop(params, [
        "action_id",
        "reason",
        "runner",
        "runners",
        "wait",
        "idempotency_key",
        "attestation"
      ])

    case Service.parse_wait(params["wait"], Service.max_wait_ms()) do
      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_wait", expected: "duration string e.g. '15s', max 60s"})

      {:ok, wait_ms} ->
        opts = %{
          runner_targets: normalize_runner_input(params),
          reason: params["reason"],
          wait_ms: wait_ms,
          idempotency_key: Idempotency.resolve(conn, params),
          attestation: rest_attestation(params)
        }

        case Service.dispatch_tool(conn, action_id, action_args, opts) do
          {:ok, runs} ->
            conn |> put_status(:accepted) |> json(%{runs: runs})

          {:error, :reason_required} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "reason_required",
              message:
                "Every action call must include a non-empty `reason` — a short sentence on " <>
                  "why. It lands in the audit log so an operator can later answer 'why did " <>
                  "this fire?'."
            })

          {:error, :runner_required, candidates} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "runner_required",
              message:
                "This action needs an explicit target — emisar never auto-picks a runner, " <>
                  "even when only one advertises it. Retry with a stable id from `candidates` " <>
                  "body, choosing from `candidates` below. Call `/runners` first if you need " <>
                  "to check which ones are online.",
              candidates: candidates
            })

          {:error, :invalid_runner_targets} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "invalid_runner_targets",
              message: "`runners` must be an array of stable runner-id strings."
            })

          {:error, :duplicate_runners} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "duplicate_runners",
              message: "Each runner may be targeted at most once per action call."
            })

          {:error, :runner_not_found, name} ->
            conn
            |> put_status(:not_found)
            |> json(%{
              error: "runner_not_found",
              runner: name,
              message:
                "No runner matching `#{name}` exists in this account. Call `GET /api/mcp/runners` " <>
                  "to see the current stable runner ids and display names."
            })

          {:error, :runner_not_allowed, name, why} ->
            conn
            |> put_status(:forbidden)
            |> json(%{
              error: "runner_not_in_key_filter",
              runner: name,
              reason: why,
              message:
                "Runner `#{name}` exists, but this API key can't dispatch to it (#{why}). " <>
                  "Either pick a runner from `GET /api/mcp/runners` (which only lists runners " <>
                  "you can reach) or ask an admin to widen the key's scope on the API keys page."
            })

          {:error, :invalid_attestation} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "invalid_attestation",
              message:
                "The supplied attestation is malformed or exceeds its bounds. " <>
                  "Submit a fresh request from a current emisar MCP bridge."
            })

          {:error, :attestation_targets_mismatch} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "attestation_targets_mismatch",
              message:
                "The attestation was not signed for the exact runner ids selected by this call. " <>
                  "Refresh the tool list and submit a fresh signed request."
            })

          {:error, :no_runner_available, :unknown_action} ->
            conn
            |> put_status(:not_found)
            |> json(%{
              error: "action_not_found",
              action_id: action_id,
              message:
                "No runner in this account advertises an action called `#{action_id}`. " <>
                  "Call `/tools` to list every action the key can dispatch — the name has " <>
                  "to match exactly (case-sensitive, including the `.` namespace)."
            })

          {:error, :no_runner_available, :scope_blocked} ->
            conn
            |> put_status(:forbidden)
            |> json(%{
              error: "no_runner_in_scope",
              action_id: action_id,
              message:
                "The action `#{action_id}` exists, but no runner you can reach is currently " <>
                  "advertising it. This usually means either (a) the runner scope of the " <>
                  "operator who minted this key excludes the runners that have it, or (b) the " <>
                  "runners that have it are disabled. Ask an admin to widen that operator's " <>
                  "runner scope on the Team page."
            })

          {:error, :too_many_runners, max} ->
            conn
            |> put_status(:bad_request)
            |> json(%{
              error: "too_many_runners",
              message:
                "Targeting more than #{max} runners in a single call isn't allowed. " <>
                  "Split the work into batches of #{max} or fewer."
            })
        end
    end
  end

  # GET /api/mcp/runs/:id
  #
  # Supports `?wait=Xs` (up to 60 seconds) for long-polling: blocks until
  # the run reaches a terminal state (or the deadline expires). Used
  # by the bridge's synthetic `wait_for_run` MCP tool so the LLM can
  # park on a pending-approval run without tight client-side polling.
  def get_run(conn, %{"id" => id} = params) do
    case Service.parse_wait(params["wait"], Service.max_get_run_wait_ms()) do
      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_wait", expected: "duration string e.g. '60s'", max: "60s"})

      {:ok, wait_ms} ->
        case Service.fetch_run(conn, id, wait_ms) do
          {:error, :not_found} ->
            conn |> put_status(:not_found) |> json(%{error: "not_found"})

          {:error, :wait_saturated} ->
            conn
            |> put_resp_header("retry-after", "1")
            |> put_status(:too_many_requests)
            |> json(%{error: "wait_saturated", retry_after_seconds: 1})

          {:ok, payload, :terminal} ->
            json(conn, payload)

          # Without a wait window the run state is returned as-is at 200,
          # terminal or not. Only an actual long-poll that times out gets
          # the 202 "still waiting" envelope below.
          {:ok, payload, :waiting} when wait_ms == 0 ->
            json(conn, payload)

          {:ok, payload, :waiting} ->
            conn
            |> put_status(:accepted)
            |> json(
              Map.merge(payload, %{
                waiting: "timeout",
                tip:
                  "Run is still not terminal. Call `wait_for_run` again with the same id to continue waiting."
              })
            )
        end
    end
  end

  # -- Param shaping --------------------------------------------------

  # The flat body names its target host(s) under `runners` (array) or the
  # singular `runner` (string) — mirroring the JSON-RPC `split_call_args`.
  # An empty/absent value fails closed with `runner_required`: Service never
  # auto-targets, even when exactly one runner advertises the action.
  defp normalize_runner_input(%{"runners" => runners}), do: runners
  defp normalize_runner_input(%{"runner" => runner}), do: [runner]
  defp normalize_runner_input(_params), do: []

  # The customer-CA contract is the exact v4 `run_action` JSON-RPC header.
  # Inline v3 envelopes cannot bind the immutable pack, exact args, public
  # runner generations, or operation identity, so this separate REST surface
  # must reject them rather than silently discard or relay weaker authority.
  defp rest_attestation(params) do
    if Map.has_key?(params, "attestation"), do: :invalid, else: nil
  end

  # -- Plugs ----------------------------------------------------------

  # Bearer resolution (emk- + emo-) and the RFC 9728 challenge live in the
  # shared `MCP.Auth`; here we only shape the REST 401 body.
  defp authenticate(conn, _opts) do
    case Auth.authenticate(conn) do
      {:ok, conn} ->
        conn

      {:error, conn} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  # The MCP tool surface is for `:mcp` keys only — an audit-export token
  # (kind: :audit_export) authenticates but has no business here. What an MCP
  # key may actually DO is decided downstream by account Policy + approval and
  # the operator's own runner scope; the key carries no per-key grant.
  defp require_mcp_key(conn, _opts) do
    if conn.assigns.api_key.kind == :mcp do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "wrong_key_kind", required: "mcp"})
      |> halt()
    end
  end
end

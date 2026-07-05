defmodule EmisarWeb.AuditExportController do
  @moduledoc """
  SIEM-shaped audit log export. One endpoint:

      GET /api/audit

  Authentication is the standard `Authorization: Bearer <api_key>`
  header. The key must be an `:audit_export` token (its own credential
  kind, minted on the audit page); an MCP key gets a 403 — the two kinds
  are separate credentials, so a log-shipping token never carries MCP
  tool access.

  Pagination is cursor-only, forward-only, and deterministic — the
  shape every SIEM ingestor expects:

    * `?since=<iso8601>` — the first call. Inclusive lower bound on
      `occurred_at`. Defaults to "since the dawn of time" — the whole
      account's history — when omitted.
    * `?cursor=<opaque>` — every subsequent call. The previous
      response's `next_cursor` value, verbatim. Takes precedence over
      `since` so resuming a poll doesn't accidentally rewind.
    * `?event_type=<a>&event_type=<b>` — restrict to specific types
      (comma-supported too).
    * `?limit=<n>` — page size. Default #{Emisar.Audit.default_export_limit()},
      hard cap #{Emisar.Audit.max_export_limit()}.

  The response is NDJSON (one event per line, `application/x-ndjson`).
  Cursor for the next page is returned both in a `Link: <…>; rel="next"`
  header (RFC 5988) AND a plain `X-Next-Cursor` header — Splunk wants
  the Link, Datadog wants the X-header. When the page is the last one,
  neither header is set.

  Resource posture:

    * Cursor-paginated `(occurred_at, id)` keyset — index-friendly,
      O(log n) per page regardless of table size.
    * Hard cap on `limit` keeps a runaway client from issuing
      single-shot scans that would page the audit table out of buffer
      pool.
    * No total-count round-trip per request (unlike the LV listing).
  """

  use EmisarWeb, :controller
  alias Emisar.{Accounts, ApiKeys, Audit, Billing}
  alias Emisar.Auth.Subject
  alias EmisarWeb.RequestContext

  plug :authenticate
  plug :require_audit_export_key
  plug :require_export_plan

  # GET /api/audit
  def index(conn, params) do
    with {:ok, opts} <- parse_params(params),
         {:ok, events} <- Audit.list_for_export(conn.assigns.current_subject, opts) do
      # Self-log the export ("watch the watchers"); the domain no-ops on an empty
      # (caught-up) page so a polling SIEM doesn't spam the log with its own event.
      Audit.record_export(conn.assigns.current_subject, opts, length(events))

      body = Enum.map_join(events, "\n", &serialize/1)

      conn
      |> maybe_put_next_cursor(events, opts[:limit])
      |> put_resp_content_type("application/x-ndjson")
      |> send_resp(200, body)
    else
      # The key KIND (audit_export) is gated by the plug, but the subject's
      # ROLE permission is the second gate inside list_for_export — a token
      # whose role lacks audit access gets a clean 403, not a 500 from an
      # assertive `{:ok, _} =` match.
      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "forbidden", message: "This token's role lacks audit access."})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_params",
          message: reason,
          docs: "Use ?since=ISO8601 OR ?cursor=<opaque> from a prior next_cursor"
        })
    end
  end

  # -- Param parsing -----------------------------------------------------

  defp parse_params(params) do
    with {:ok, types} <- parse_event_types(params),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, cursor_or_since} <- parse_cursor_or_since(params) do
      {:ok, Keyword.merge([limit: limit, event_types: types], cursor_or_since)}
    end
  end

  defp parse_event_types(params) do
    raw =
      params
      |> Map.get("event_type", [])
      |> List.wrap()
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, raw}
  end

  defp parse_limit(nil), do: {:ok, Audit.default_export_limit()}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "limit must be a positive integer"}
    end
  end

  defp parse_limit(_), do: {:error, "limit must be a positive integer"}

  defp parse_cursor_or_since(%{"cursor" => c}) when is_binary(c) and c != "" do
    case decode_cursor(c) do
      {:ok, ts, id} -> {:ok, [after: {ts, id}]}
      :error -> {:error, "cursor is malformed"}
    end
  end

  defp parse_cursor_or_since(%{"since" => since}) when is_binary(since) and since != "" do
    case DateTime.from_iso8601(since) do
      {:ok, ts, _} -> {:ok, [since: ts]}
      _ -> {:error, "since must be an ISO 8601 timestamp"}
    end
  end

  defp parse_cursor_or_since(_), do: {:ok, []}

  # -- Cursor encoding --------------------------------------------------
  #
  # The cursor is "`<iso8601>|<uuid>`" base64url-encoded. Opaque to
  # consumers — they're meant to copy-paste the prior `next_cursor`
  # value, not construct one themselves. Keeping it opaque means we can
  # change the format later without breaking integrations.

  defp encode_cursor(%DateTime{} = ts, id) when is_binary(id) do
    raw = DateTime.to_iso8601(ts) <> "|" <> id
    Base.url_encode64(raw, padding: false)
  end

  defp decode_cursor(encoded) when is_binary(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false),
         [ts_str, id] <- String.split(raw, "|", parts: 2),
         {:ok, ts, _} <- DateTime.from_iso8601(ts_str) do
      {:ok, ts, id}
    else
      _ -> :error
    end
  end

  # -- Response shaping -------------------------------------------------

  # When we returned a full page, surface the cursor for the next one.
  # Below-limit pages mean "you're caught up" — no next cursor, so the
  # SIEM can sleep until its next poll.
  defp maybe_put_next_cursor(conn, events, limit) when length(events) == limit do
    last = List.last(events)
    cursor = encode_cursor(last.occurred_at, last.id)

    conn
    |> put_resp_header("x-next-cursor", cursor)
    |> put_resp_header(
      "link",
      ~s(<#{next_page_url(conn, cursor)}>; rel="next")
    )
  end

  defp maybe_put_next_cursor(conn, _events, _limit), do: conn

  defp next_page_url(conn, cursor) do
    base = "#{conn.scheme}://#{conn.host}#{conn.request_path}"
    params = Map.put(conn.query_params || %{}, "cursor", cursor) |> Map.delete("since")
    base <> "?" <> URI.encode_query(params)
  end

  # SIEMs want exact JSON they can ingest as-is. Project every column
  # the audit row stores — including the request metadata the boundary
  # captured on the caller's %RequestContext{} — so downstream rules can
  # correlate by `request_id` / `ip_address` / `user_agent`.
  defp serialize(%Emisar.Audit.Event{} = event) do
    %{
      id: event.id,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      account_id: event.account_id,
      event_type: event.event_type,
      actor_kind: event.actor_kind,
      actor_id: event.actor_id,
      actor_label: event.actor_label,
      target_kind: event.target_kind,
      target_id: event.target_id,
      target_label: event.target_label,
      ip_address: event.ip_address,
      user_agent: event.user_agent,
      request_id: event.request_id,
      payload: event.payload
    }
    |> Jason.encode!()
  end

  # -- Auth (mirrors MCPController) -------------------------------------

  defp authenticate(conn, _opts) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         %{} = key <- ApiKeys.peek_api_key_by_secret(raw),
         {:ok, account} <- Accounts.fetch_account_by_id(key.account_id) do
      conn
      |> assign(:api_key, key)
      |> assign(
        :current_subject,
        Subject.for_api_key(key, account, RequestContext.from_conn(conn))
      )
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()
    end
  end

  # Audit export (SIEM API + CSV download alike) is a Team+ feature — the
  # in-console trail is on every plan; taking the data out is paid. 403 with
  # an upgrade pointer, mirroring the scope error's shape.
  defp require_export_plan(conn, _opts) do
    if Billing.audit_export_available?(conn.assigns.current_subject.account) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "plan_required",
        required: "team",
        message: "Audit export is available on the Team plan. Upgrade in Settings → Billing."
      })
      |> halt()
    end
  end

  # The audit stream is for `:audit_export` tokens only — an MCP key
  # authenticates but is the wrong credential kind here. The subject's ROLE
  # permission is the second gate inside `list_for_export`.
  defp require_audit_export_key(conn, _opts) do
    if conn.assigns.api_key.kind == :audit_export do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "wrong_key_kind",
        required: "audit_export",
        message: "Mint an audit export token on the audit page's SIEM export section."
      })
      |> halt()
    end
  end
end

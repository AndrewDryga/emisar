defmodule EmisarWeb.OAuthController do
  @moduledoc """
  OAuth 2.1 authorization endpoints for remote MCP clients (Claude.ai,
  ChatGPT). Implements exactly the subset the MCP authorization spec
  requires:

    * Client ID Metadata Documents — the preferred mechanism: the client
      identifies itself by an HTTPS URL that `Emisar.OAuth` resolves and
      validates at /authorize. There is no endpoint to call.
    * `POST /oauth/register` — Dynamic Client Registration (RFC 7591),
      deprecated but still supported. Public; the client self-registers
      and gets back a `client_id`.
    * `GET  /oauth/authorize` — renders a consent screen to the
      signed-in operator (behind `:require_signed_in`), who picks which of
      this browser's signed-in workspaces the grant lands in.
    * `POST /oauth/authorize` — records the consent decision; on approve
      mints a single-use code bound to the PKCE challenge and redirects
      back to the client.
    * `POST /oauth/token` — `authorization_code` + `refresh_token`
      grants; returns the standard JSON token response.

  All issuance + validation lives in `Emisar.OAuth`; this controller is
  just the HTTP shell (param plumbing, consent render, OAuth-shaped
  errors).
  """
  use EmisarWeb, :controller
  alias Emisar.{Accounts, OAuth}
  alias Emisar.Auth.Subject
  alias EmisarWeb.UserAuth

  plug :put_layout, html: {EmisarWeb.Layouts, :app}
  # Auth surface — keep it out of search indexes.
  plug :put_noindex when action in [:authorize, :authorize_submit]

  # Unauthenticated, abuse-prone: /register INSERTs a client row per call and
  # /token is a credential-exchange brute-force surface. Cap per IP.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "oauth_register", limit: 20, window_ms: 3_600_000] when action == :register

  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "oauth_token", limit: 60, window_ms: 60_000] when action == :token

  # Authorizing a Client ID Metadata Document client makes the server fetch the
  # client's own URL, so cap how often one caller can trigger that outbound
  # request even though the endpoint already requires a signed-in operator.
  plug EmisarWeb.Plugs.RateLimit,
       [bucket: "oauth_authorize", limit: 60, window_ms: 60_000]
       when action in [:authorize, :authorize_submit]

  defp put_noindex(conn, _opts), do: assign(conn, :noindex, true)

  # -- Dynamic Client Registration (RFC 7591) -------------------------

  # POST /oauth/register
  def register(conn, params) do
    case OAuth.register_client(params) do
      {:ok, client} ->
        conn
        |> put_status(:created)
        |> json(registration_response(client))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_client_metadata",
          error_description: changeset_errors(changeset)
        })
    end
  end

  # -- Authorization (consent) ----------------------------------------

  # GET /oauth/authorize — validate the request, then render consent.
  #
  # Per OAuth 2.1: errors caused by a bad `client_id`/`redirect_uri`
  # MUST NOT redirect (we can't trust where they'd land) — show an error
  # page instead. Everything else redirects back with `error=...`, on the
  # callback the domain proved against the client's registration.
  def authorize(conn, params) do
    with {:ok, client} <- OAuth.fetch_client(params["client_id"]),
         {:ok, _redirect_uri} <- OAuth.validate_authorization_request(client, params) do
      render_consent(conn, client, params)
    else
      {:error, {:oauth, code, redirect_uri}} ->
        redirect_error(conn, redirect_uri, code, params["state"])

      _ ->
        render_invalid(conn, "We couldn't verify the app or its return address.")
    end
  end

  # POST /oauth/authorize — the operator approved or denied.
  def authorize_submit(conn, params) do
    case OAuth.fetch_client(params["client_id"]) do
      {:ok, client} ->
        submit_decision(conn, client, params)

      {:error, :not_found} ->
        render_invalid(conn, "We couldn't verify the app or its return address.")
    end
  end

  # `issue_code/4` re-validates the request against the client's own locked row
  # and enforces the CHOSEN account's role + require_sso / require_mfa controls,
  # so approval hands it the request whole and maps what comes back. Rendering
  # consent mints nothing, which is why nothing here is gated on the SESSION
  # account — that would block granting a DIFFERENT, compliant account.
  defp submit_decision(conn, client, %{"decision" => "approve"} = params) do
    case consent_subject(conn, params) do
      {:ok, subject} ->
        approve_consent(conn, client, params, subject)

      # A tampered/blank form value or a membership revoked between render
      # and submit — no code, no redirect to the client, and no hint the
      # account exists.
      {:error, :not_found} ->
        render_invalid(
          conn,
          "That workspace isn't available to you. Restart the connection and choose a workspace you can access."
        )
    end
  end

  # Deny still proves the callback before bouncing to it: an unregistered
  # redirect_uri is an error page, and a malformed request reports its own
  # protocol error rather than a denial the client never asked about.
  defp submit_decision(conn, client, params) do
    case OAuth.validate_authorization_request(client, params) do
      {:ok, redirect_uri} ->
        redirect_error(conn, redirect_uri, "access_denied", params["state"])

      {:error, {:oauth, code, redirect_uri}} ->
        redirect_error(conn, redirect_uri, code, params["state"])

      {:error, :invalid_redirect_uri} ->
        render_invalid(conn, "We couldn't verify the app or its return address.")
    end
  end

  defp approve_consent(conn, client, params, %Subject{} = subject) do
    state = params["state"]
    grantee = consent_grantee(params)

    case OAuth.issue_code(client, params, grantee, subject) do
      {:ok, code, redirect_uri} ->
        redirect_back(conn, redirect_uri, %{code: code, state: state})

      {:error, {:oauth, error_code, redirect_uri}} ->
        redirect_error(conn, redirect_uri, error_code, state)

      {:error, :unauthorized} ->
        render_invalid(conn, unauthorized_message(grantee))

      {:error, :runner_access_exceeds_subject} ->
        render_invalid(
          conn,
          "That service account can reach runners or packs you can't, so you can't connect an " <>
            "app as it. Ask an owner, or choose another service account."
        )

      {:error, :sso_required} ->
        render_invalid(
          conn,
          "This workspace requires single sign-on. Sign in to it with your identity provider " <>
            "before connecting an AI agent."
        )

      {:error, :mfa_required} ->
        render_invalid(
          conn,
          "This workspace requires multi-factor authentication. Open its console and set up or " <>
            "verify MFA for this browser before connecting an AI agent."
        )

      {:error, :invalid_redirect_uri} ->
        render_invalid(conn, "We couldn't verify the app or its return address.")

      # A revoked seat, or a write that failed for a reason we can't shape into
      # an OAuth error — never bounce to a callback the domain didn't hand back.
      {:error, _reason} ->
        render_invalid(
          conn,
          "That connection couldn't be authorized. Reload the page and try again."
        )
    end
  end

  # The consent form posts which workspace the operator chose to grant. The
  # backing key is minted under the Member of this browser's live session in
  # that workspace — resolved fresh from the cookie entry and its row, never
  # trusted from the form. The rendered form always posts an explicit
  # account_id (select or hidden field), so a request without one is a stale or
  # handcrafted form — it must not silently mint into some default workspace.
  defp consent_subject(conn, %{"account_id" => account_id})
       when is_binary(account_id) and account_id != "",
       do: UserAuth.subject_for_account(conn, account_id)

  defp consent_subject(_conn, _params), do: {:error, :not_found}

  # Who the connection acts as. The domain re-checks that a service account
  # belongs to the chosen workspace and that this member may act for it.
  defp consent_grantee(%{"connect_as" => "new_service_account"}), do: :new_service_account

  defp consent_grantee(%{"connect_as" => id}) when is_binary(id) and id not in ["", "member"],
    do: {:service_account, id}

  defp consent_grantee(_params), do: :member

  defp unauthorized_message(:member),
    do: "Your role can't connect an AI agent. Ask a workspace administrator for access."

  defp unauthorized_message(_grantee),
    do: "Only owners and admins can connect an app as a service account."

  # -- Token endpoint -------------------------------------------------

  # POST /oauth/token
  def token(conn, %{"grant_type" => "authorization_code"} = params) do
    respond_with_tokens(conn, OAuth.exchange_code(params))
  end

  def token(conn, %{"grant_type" => "refresh_token"} = params) do
    respond_with_tokens(conn, OAuth.refresh(params))
  end

  def token(conn, _params), do: token_error(conn, :unsupported_grant_type)

  defp respond_with_tokens(conn, {:ok, tokens}), do: json(conn, token_response(tokens))
  defp respond_with_tokens(conn, {:error, reason}), do: token_error(conn, reason)

  # -- Rendering / redirects ------------------------------------------

  defp render_consent(conn, client, params) do
    requested = scopes(params["scope"])
    sessions = consent_sessions(conn)

    conn
    |> allow_oauth_form_navigation(params["redirect_uri"])
    |> render(:consent,
      client_name: client_label(client),
      # The origin codes are delivered to — validated against the client's
      # registration — so the operator authorizes a concrete callback, not just
      # a self-reported (spoofable) client name.
      callback_origin: callback_label(params["redirect_uri"]),
      # Which workspace the grant lands in: the browser's one signed-in
      # workspace is preselected and hidden; with several, the operator picks
      # at the point of decision (no default — the key used to silently ride a
      # session default, an easy way to connect Claude.ai to the wrong, empty
      # workspace).
      sessions: sessions,
      # Who the connection acts as, offered only where the member may connect
      # an app as a service account; nil keeps the page as before.
      connect_as_options: connect_as_options(sessions, client),
      scopes: requested,
      # Echoed back verbatim as hidden fields on the consent form.
      params: %{
        "client_id" => params["client_id"],
        "redirect_uri" => params["redirect_uri"],
        "response_type" => params["response_type"],
        "scope" => Enum.join(requested, " "),
        "state" => params["state"],
        "code_challenge" => params["code_challenge"],
        "code_challenge_method" => params["code_challenge_method"] || "S256",
        "resource" => params["resource"]
      },
      page_title: "Authorize #{client_label(client)}"
    )
  end

  defp render_invalid(conn, message) do
    conn
    |> put_status(:bad_request)
    |> render(:error, message: message, page_title: "Authorization error")
  end

  # Append OAuth result params to the client's redirect_uri and 302 to
  # it (external — it's the client's origin, e.g. claude.ai). Every
  # authorization response — success and error — carries the RFC 9207 `iss`
  # so the client can detect authorization-server mix-up before redeeming
  # the code; the value must equal the discovery metadata's `issuer`.
  defp redirect_back(conn, redirect_uri, extra) do
    params = Map.put(extra, :iss, EmisarWeb.Endpoint.url())
    redirect(conn, external: append_query(redirect_uri, params))
  end

  defp redirect_error(conn, redirect_uri, error_code, state) do
    redirect_back(conn, redirect_uri, %{error: error_code, state: state})
  end

  # ChatGPT's sandboxed OAuth document rejects host sources for the consent POST,
  # even when the configured server origin is named explicitly. Allow HTTPS
  # navigation on this validated consent page only; exact redirect-uri matching
  # still controls where the authorization code can land. Keep explicit origins
  # for local HTTP endpoints and registered loopback callbacks.
  defp allow_oauth_form_navigation(conn, redirect_uri) do
    origins =
      [EmisarWeb.Endpoint.url(), redirect_uri]
      |> Enum.map(&form_action_origin/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    sources = ["https:" | origins]

    extra =
      conn.assigns
      |> Map.get(:csp_extra, %{})
      |> Map.update("form-action", sources, &Enum.uniq(&1 ++ sources))

    assign(conn, :csp_extra, extra)
  end

  defp form_action_origin(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["https", "http"] and is_binary(host) ->
        scheme <> "://" <> csp_host(host) <> csp_port(parsed)

      _ ->
        nil
    end
  end

  defp form_action_origin(_), do: nil

  defp callback_label(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme} when scheme in ["https", "http"] ->
        form_action_origin(uri)

      %URI{scheme: scheme} = parsed when is_binary(scheme) ->
        parsed
        |> Map.put(:query, nil)
        |> Map.put(:fragment, nil)
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp callback_label(_), do: nil

  defp csp_host(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp csp_port(%URI{scheme: "https", port: port}) when port in [nil, 443], do: ""
  defp csp_port(%URI{scheme: "http", port: port}) when port in [nil, 80], do: ""
  defp csp_port(%URI{port: port}) when is_integer(port), do: ":" <> Integer.to_string(port)
  defp csp_port(_), do: ""

  # -- Token response shaping -----------------------------------------

  defp token_response(tokens) do
    base = %{
      access_token: tokens.access_token,
      token_type: tokens.token_type,
      expires_in: tokens.expires_in,
      scope: tokens.scope
    }

    if tokens.refresh_token,
      do: Map.put(base, :refresh_token, tokens.refresh_token),
      else: base
  end

  # RFC 6749 §5.2 maps `server_error` to HTTP 500: it means the authorization
  # server hit an unexpected condition, not that the request was wrong. Sending
  # it as 400 told every client the failure was PERMANENT, so a transient
  # database blip made the client abandon its code and the operator redo the
  # whole browser authorization. Every other code here really is the caller's
  # fault and stays 400.
  defp token_error(conn, :server_error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: oauth_error(:server_error)})
  end

  defp token_error(conn, reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: oauth_error(reason)})
  end

  defp oauth_error(:invalid_grant), do: "invalid_grant"
  defp oauth_error(:invalid_client), do: "invalid_client"
  defp oauth_error(:invalid_target), do: "invalid_target"
  defp oauth_error(:unsupported_grant_type), do: "unsupported_grant_type"
  defp oauth_error(:server_error), do: "server_error"
  defp oauth_error(_), do: "invalid_request"

  # -- Registration response ------------------------------------------

  defp registration_response(client) do
    %{
      client_id: client.id,
      client_id_issued_at: DateTime.to_unix(client.inserted_at),
      client_name: client.client_name,
      redirect_uris: client.redirect_uris,
      grant_types: client.grant_types,
      response_types: client.response_types,
      token_endpoint_auth_method: "none",
      scope: client.scope
    }
    |> put_application_type(client.metadata)
  end

  # RFC 7591: the response echoes registered metadata — `application_type`
  # only when the client declared one (absent means the permissive default).
  defp put_application_type(response, %{"application_type" => application_type}),
    do: Map.put(response, :application_type, application_type)

  defp put_application_type(response, _metadata), do: response

  # -- Small helpers --------------------------------------------------

  defp scopes(nil), do: ["mcp", "offline_access"]

  defp scopes(scope) when is_binary(scope) do
    requested = scope |> String.split(~r/\s+/, trim: true)
    supported = OAuth.supported_scopes()
    keep = Enum.filter(requested, &(&1 in supported))
    if keep == [], do: ["mcp"], else: keep
  end

  defp client_label(%{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_label(_), do: "An MCP client"

  # The consent picker's options: each workspace this browser is signed in to,
  # named with the Member the grant would belong to there. `require_signed_in`
  # already pruned dead entries and sorted by workspace name.
  defp consent_sessions(conn) do
    Enum.map(conn.assigns.signed_in_sessions, fn %{membership: membership} ->
      %{
        account: membership.account,
        member_label: member_label(membership),
        service_accounts: connectable_service_accounts(conn, membership.account)
      }
    end)
  end

  # nil where this browser's member may not connect an app as a service account,
  # so the page never offers a choice the domain would refuse.
  defp connectable_service_accounts(conn, account) do
    with {:ok, subject} <- UserAuth.subject_for_account(conn, account.id),
         {:ok, service_accounts} <- Accounts.list_service_accounts(subject) do
      service_accounts
    else
      _ -> nil
    end
  end

  defp connect_as_options(sessions, client) do
    case Enum.reject(sessions, &is_nil(&1.service_accounts)) do
      [] ->
        nil

      managed ->
        service_account_options =
          Enum.flat_map(managed, &service_account_options(&1, sessions)) ++
            [{new_service_account_label(client), "new_service_account"}]

        [
          {you_label(sessions), "member"},
          {"Service accounts", service_account_options}
        ]
    end
  end

  defp new_service_account_label(%{client_name: name}) when is_binary(name) and name != "",
    do: "New service account named #{name}"

  defp new_service_account_label(_client), do: "New service account"

  defp you_label([session]), do: "You (#{session.member_label})"
  defp you_label(_sessions), do: "You"

  # With several workspaces signed in, each service account names its own.
  defp service_account_options(session, [_]),
    do: Enum.map(session.service_accounts, &{Accounts.member_display_name(&1), &1.id})

  defp service_account_options(session, _sessions) do
    Enum.map(session.service_accounts, fn service_account ->
      {"#{Accounts.member_display_name(service_account)} (#{session.account.name})",
       service_account.id}
    end)
  end

  defp member_label(%Accounts.Membership{email: email}) when is_binary(email), do: email

  defp member_label(%Accounts.Membership{} = membership),
    do: Accounts.member_display_name(membership)

  defp append_query(uri_string, extra) do
    uri = URI.parse(uri_string)
    existing = URI.decode_query(uri.query || "")

    merged =
      extra
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.reduce(existing, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)

    %{uri | query: URI.encode_query(merged)} |> URI.to_string()
  end

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end

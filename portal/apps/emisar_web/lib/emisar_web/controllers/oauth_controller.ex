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
      logged-in operator (behind `:require_authenticated_user`).
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
        render_invalid(conn, "Unknown client or unregistered redirect URI.")
    end
  end

  # POST /oauth/authorize — the operator approved or denied.
  def authorize_submit(conn, params) do
    case OAuth.fetch_client(params["client_id"]) do
      {:ok, client} -> submit_decision(conn, client, params)
      {:error, :not_found} -> render_invalid(conn, "Unknown client or unregistered redirect URI.")
    end
  end

  # `issue_code/3` re-validates the request against the client's own locked row
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
          "That account isn't available to your user. Reload the page and try again."
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
        render_invalid(conn, "Unknown client or unregistered redirect URI.")
    end
  end

  defp approve_consent(conn, client, params, %Subject{} = subject) do
    state = params["state"]

    case OAuth.issue_code(client, params, subject) do
      {:ok, code, redirect_uri} ->
        redirect_back(conn, redirect_uri, %{code: code, state: state})

      {:error, {:oauth, error_code, redirect_uri}} ->
        redirect_error(conn, redirect_uri, error_code, state)

      {:error, :unauthorized} ->
        render_invalid(
          conn,
          "Your role can't connect an MCP client. Connecting one mints an API key, " <>
            "which requires key-issue permission — ask an account admin to connect it."
        )

      {:error, :sso_required} ->
        render_invalid(
          conn,
          "This team requires single sign-on. Sign in to it with your identity provider " <>
            "before connecting an MCP client."
        )

      {:error, :mfa_required} ->
        render_invalid(
          conn,
          "This team requires two-factor authentication. Open its console and set up or " <>
            "verify 2FA for this browser before connecting an MCP client."
        )

      {:error, :invalid_redirect_uri} ->
        render_invalid(conn, "Unknown client or unregistered redirect URI.")

      # A revoked seat, or a write that failed for a reason we can't shape into
      # an OAuth error — never bounce to a callback the domain didn't hand back.
      {:error, _reason} ->
        render_invalid(
          conn,
          "That connection couldn't be authorized. Reload the page and try again."
        )
    end
  end

  # The consent form posts which account the operator chose to grant. The
  # backing key is minted under a membership THEY hold in that account —
  # resolved fresh against their non-suspended memberships, never trusted from
  # the form. The rendered form always posts an explicit account_id (select or
  # hidden field), so a request without one is a stale or handcrafted form —
  # it must not silently mint into the session's account.
  defp consent_subject(conn, %{"account_id" => account_id})
       when is_binary(account_id) and account_id != "",
       do: UserAuth.subject_for_account(conn, account_id)

  defp consent_subject(_conn, _params), do: {:error, :not_found}

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

    conn
    |> allow_oauth_form_navigation(params["redirect_uri"])
    |> render(:consent,
      client_name: client_label(client),
      # The origin codes are delivered to — validated against the client's
      # registration — so the operator authorizes a concrete callback, not just
      # a self-reported (spoofable) client name.
      callback_origin: callback_label(params["redirect_uri"]),
      account_name: account_label(conn),
      # Which account the grant lands in: a picker when the operator belongs to
      # several (the key used to silently ride the session default — an easy
      # way to connect Claude.ai to the wrong, empty account), preselecting the
      # session-current one.
      accounts: consent_accounts(conn),
      selected_account_id: conn.assigns.current_account.id,
      user_email: user_email(conn),
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

  defp account_label(conn) do
    case conn.assigns[:current_account] do
      %{name: name} when is_binary(name) -> name
      _ -> "your account"
    end
  end

  defp user_email(conn) do
    case conn.assigns[:current_user] do
      %{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  # Every (non-suspended) account the operator belongs to — the consent
  # picker's options. The read failing must never block consent, so it
  # degrades to the session account (today's single-account behavior).
  defp consent_accounts(conn) do
    case Accounts.list_accounts_for_user(conn.assigns.current_subject, page: [limit: 100]) do
      {:ok, accounts, _meta} -> accounts
      _ -> [conn.assigns.current_account]
    end
  end

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

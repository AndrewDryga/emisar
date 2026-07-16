defmodule EmisarWeb.OAuthController do
  @moduledoc """
  OAuth 2.1 authorization endpoints for remote MCP clients (Claude.ai,
  ChatGPT). Implements exactly the subset the MCP authorization spec
  requires:

    * `POST /oauth/register` — Dynamic Client Registration (RFC 7591).
      Public; the client self-registers and gets back a `client_id`.
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
  alias EmisarWeb.MCP.Auth, as: MCPAuth
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
  # page instead. Everything else redirects back with `error=...`.
  def authorize(conn, params) do
    with {:ok, client} <- OAuth.fetch_client(params["client_id"]),
         :ok <- check_redirect(client, params["redirect_uri"]) do
      case validate_request(params) do
        :ok ->
          render_consent(conn, client, params)

        {:error, code} ->
          redirect_error(conn, params["redirect_uri"], code, params["state"])
      end
    else
      _ -> render_invalid(conn, "Unknown client or unregistered redirect URI.")
    end
  end

  # POST /oauth/authorize — the operator approved or denied.
  def authorize_submit(conn, params) do
    redirect_uri = params["redirect_uri"]
    state = params["state"]

    with {:ok, client} <- OAuth.fetch_client(params["client_id"]),
         :ok <- check_redirect(client, redirect_uri),
         :ok <- validate_request(params) do
      case params["decision"] do
        "approve" ->
          case consent_subject(conn, params) do
            {:ok, subject} ->
              approve_consent(conn, client, params, subject, redirect_uri, state)

            # A tampered/blank form value or a membership revoked between render
            # and submit — no code, no redirect to the client, and no hint the
            # account exists.
            {:error, :not_found} ->
              render_invalid(
                conn,
                "That account isn't available to your user. Reload the page and try again."
              )
          end

        _ ->
          redirect_error(conn, redirect_uri, "access_denied", state)
      end
    else
      {:error, code} when is_binary(code) -> redirect_error(conn, redirect_uri, code, state)
      _ -> render_invalid(conn, "Unknown client or unregistered redirect URI.")
    end
  end

  defp approve_consent(conn, client, params, subject, redirect_uri, state) do
    case OAuth.issue_code(client, params, subject) do
      {:ok, code} ->
        redirect_back(conn, redirect_uri, %{code: code, state: state})

      {:error, :unauthorized} ->
        render_invalid(
          conn,
          "Your role can't connect an MCP client. Connecting one mints an API key, " <>
            "which requires key-issue permission — ask an account admin to connect it."
        )

      {:error, _reason} ->
        redirect_error(conn, redirect_uri, "server_error", state)
    end
  end

  # The consent form posts which account the operator chose to grant. The
  # backing key is minted under a membership THEY hold in that account —
  # resolved fresh against their non-suspended memberships, never trusted from
  # the form. An absent param (a consent page rendered before the picker
  # existed) falls back to the session's current account, the prior behavior.
  defp consent_subject(conn, %{"account_id" => account_id})
       when is_binary(account_id) and account_id != "",
       do: UserAuth.subject_for_account(conn, account_id)

  defp consent_subject(conn, _params), do: {:ok, conn.assigns.current_subject}

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
    |> allow_oauth_form_redirect(params["redirect_uri"])
    |> render(:consent,
      client_name: client_label(client),
      # The origin codes are delivered to — validated against the client's
      # registration — so the operator authorizes a concrete callback, not just
      # a self-reported (spoofable) client name.
      callback_origin: form_action_origin(params["redirect_uri"]),
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
  # it (external — it's the client's origin, e.g. claude.ai).
  defp redirect_back(conn, redirect_uri, extra) do
    redirect(conn, external: append_query(redirect_uri, extra))
  end

  defp redirect_error(conn, redirect_uri, error_code, state) do
    redirect_back(conn, redirect_uri, %{error: error_code, state: state})
  end

  # Some browser CSP implementations apply `form-action` across the OAuth form
  # navigation chain, including the 302 back to the client's callback. Keep the
  # base policy strict and widen only this consent page to the already-validated
  # callback origin.
  defp allow_oauth_form_redirect(conn, redirect_uri) do
    case form_action_origin(redirect_uri) do
      nil ->
        conn

      origin ->
        extra =
          conn.assigns
          |> Map.get(:csp_extra, %{})
          |> Map.update("form-action", [origin], &(&1 ++ [origin]))

        assign(conn, :csp_extra, extra)
    end
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

  defp csp_host(host) do
    if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
  end

  defp csp_port(%URI{scheme: "https", port: port}) when port in [nil, 443], do: ""
  defp csp_port(%URI{scheme: "http", port: port}) when port in [nil, 80], do: ""
  defp csp_port(%URI{port: port}) when is_integer(port), do: ":" <> Integer.to_string(port)
  defp csp_port(_), do: ""

  # -- Validation -----------------------------------------------------

  # redirect_uri must EXACTLY match one the client registered.
  defp check_redirect(client, redirect_uri) when is_binary(redirect_uri) do
    if redirect_uri in (client.redirect_uris || []), do: :ok, else: :error
  end

  defp check_redirect(_client, _), do: :error

  defp validate_request(params) do
    cond do
      params["response_type"] != "code" -> {:error, "unsupported_response_type"}
      not is_binary(params["code_challenge"]) -> {:error, "invalid_request"}
      params["code_challenge"] == "" -> {:error, "invalid_request"}
      # MCP mandates S256; reject "plain" (absent defaults to S256).
      params["code_challenge_method"] not in [nil, "S256"] -> {:error, "invalid_request"}
      params["resource"] != MCPAuth.resource() -> {:error, "invalid_target"}
      true -> :ok
    end
  end

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
  end

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
    case Accounts.list_accounts_for_user(conn.assigns.current_subject, page_size: 100) do
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

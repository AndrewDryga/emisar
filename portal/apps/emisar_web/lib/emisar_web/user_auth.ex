defmodule EmisarWeb.UserAuth do
  @moduledoc """
  The workspace session boundary: the browser's workspace sessions in the
  `_emisar_web_key` cookie, the plugs and LiveView hooks that resolve them, and
  sign-in and sign-out.

  The cookie's `"sessions"` key holds up to six `{account_id, raw_token}`
  entries, one per workspace, oldest first. A request always names its
  workspace — the URL, a signed flow state or an explicit pick — and uses only
  that workspace's entry; `Emisar.Auth` refuses a token presented for a
  workspace its row does not belong to. `"browser_id"` is this browser's own
  random id: every sign-in hands it to the domain, so a sign-out ends every
  session the browser minted, including one a concurrent tab left out of the
  final cookie.

  A sign-in renews the session id and CSRF token and carries the other
  workspaces' entries over; the entry it replaces, and the oldest one a
  seventh workspace pushes out, are revoked in the same request. Sign-out ends
  every session in the cookie, in every workspace, and clears the cookie. The
  staff realm (`EmisarWeb.StaffAuth`) never reads or writes this cookie.
  """

  use EmisarWeb, :verified_routes
  import Plug.Conn
  import Phoenix.Controller
  alias Emisar.{Accounts, ApiKeys, Approvals, Auth}
  alias Emisar.Auth.Subject
  alias Emisar.{Billing, Catalog, Crypto, Marketing, Runners, SSO}
  alias EmisarWeb.{Analytics, BillingIntent, MarketingAttribution, RecentAccounts}
  alias EmisarWeb.{RequestContext, ShellChrome}

  # Firezone's cap: six entries stay far under the 4 KB cookie limit.
  @max_sessions 6
  # The cookie session is ~4 KiB, so a stored return path is bounded.
  @return_to_max_bytes 1024
  # `Process.send_after/3` waits at most ~49.7 days, so a longer wait re-arms daily.
  @session_expiry_check_ms 24 * 60 * 60 * 1000

  # -- The cookie -----------------------------------------------------

  @doc """
  The browser's workspace sessions from its cookie, or from a LiveView session
  map: `{account_id, raw_token}` pairs, oldest first, at most six, one per
  workspace. Anything else in the key is ignored.
  """
  def session_entries(%Plug.Conn{} = conn), do: normalize_entries(get_session(conn, :sessions))
  def session_entries(%{} = session), do: normalize_entries(session["sessions"])

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.filter(&valid_entry?/1)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {account_id, _token} -> account_id end)
    |> Enum.take(@max_sessions)
    |> Enum.reverse()
  end

  defp normalize_entries(_entries), do: []

  defp valid_entry?({account_id, token}) when is_binary(account_id) and is_binary(token),
    do: match?({:ok, _uuid}, Ecto.UUID.cast(account_id))

  defp valid_entry?(_entry), do: false

  defp entry_for_account(conn_or_session, account_id),
    do: List.keyfind(session_entries(conn_or_session), account_id, 0)

  @doc "This browser's random id from its cookie or a LiveView session map, or nil before its first sign-in."
  def browser_id(%Plug.Conn{} = conn), do: valid_browser_id(get_session(conn, :browser_id))
  def browser_id(%{} = session), do: valid_browser_id(session["browser_id"])

  defp valid_browser_id(id) when is_binary(id) and byte_size(id) > 0, do: id
  defp valid_browser_id(_id), do: nil

  @doc """
  This browser's random id, minted into its workspace session on first use.
  Every sign-in passes it to the domain (each `complete_*`, both invitation SSO
  calls), which stores only its digest on the session it mints, so a sign-out
  from this browser ends every session the browser minted. Returns
  `{conn, browser_id}`.
  """
  def fetch_browser_id(%Plug.Conn{} = conn) do
    case browser_id(conn) do
      nil ->
        id = Crypto.random_secret()
        {put_session(conn, :browser_id, id), id}

      id ->
        {conn, id}
    end
  end

  @doc """
  The workspace whose invitation this browser is finishing through single
  sign-on, or nil. The invitee's emailed code proved the invited address in a
  workspace that refuses email sign-in, and the proof waits in the encrypted
  session (never a URL) until the SSO step uses it; it counts only while it
  verifies for this browser.
  """
  def invitation_sso_account_id(conn_or_session) do
    with proof when is_binary(proof) <- session_value(conn_or_session, "invitation_sso_proof"),
         browser_id when is_binary(browser_id) <- browser_id(conn_or_session),
         {:ok, %{account_id: account_id}} <- Auth.verify_invitation_sso_proof(proof, browser_id) do
      account_id
    else
      _ -> nil
    end
  end

  defp session_value(%Plug.Conn{} = conn, key), do: get_session(conn, key)
  defp session_value(%{} = session, key), do: session[key]

  # -- Sign-in --------------------------------------------------------

  @doc """
  Installs the email-code session `Emisar.Auth` minted for `membership` (its
  workspace preloaded): factor one only, so the provenance is fixed here at
  `:magic_link` with no second factor. `registered?` is true for the sign-up
  that just created the workspace.
  """
  def log_in_magic_link_member(conn, %Accounts.Membership{} = membership, token, registered?),
    do: finish_log_in(conn, membership, token, :magic_link, false, registered?)

  @doc """
  Installs the email-code session `Emisar.Auth` minted after the second factor
  passed — as `log_in_magic_link_member/4` with the second factor fixed here.
  """
  def log_in_magic_link_mfa_member(conn, %Accounts.Membership{} = membership, token, registered?),
    do: finish_log_in(conn, membership, token, :magic_link, true, registered?)

  @doc """
  Completes an SSO sign-in: `auth` is `SSO.complete_auth/4`'s verified
  `%{membership, identity, provider}` and `account` the provider's workspace.
  The domain mints the session under its locks and decides the IdP MFA stamp;
  no web caller chooses it. Returns `{:ok, conn}` or `{:error,
  :account_disabled | :provider_disabled | :membership_unavailable}`.
  """
  def log_in_sso_member(
        conn,
        %{
          membership: %Accounts.Membership{} = membership,
          identity: identity,
          provider: provider
        },
        %Accounts.Account{} = account
      ) do
    {conn, browser_id} = fetch_browser_id(conn)
    context = RequestContext.from_conn(conn)

    case Auth.complete_sso_sign_in(membership, identity, provider, browser_id, context) do
      {:ok, token, mfa} ->
        {:ok, finish_log_in(conn, %{membership | account: account}, token, :sso, mfa, false)}

      {:error, reason}
      when reason in [:account_disabled, :provider_disabled, :membership_unavailable] ->
        {:error, reason}

      {:error, reason} ->
        raise "could not complete SSO sign-in: #{inspect(reason)}"
    end
  end

  @doc """
  Installs the SSO session `SSO.complete_invitation_sso_sign_in/5` minted when
  an invitee joined through the workspace's identity provider.
  """
  def log_in_invitation_sso_member(conn, %Accounts.Membership{} = membership, token),
    do: finish_log_in(conn, membership, token, :sso, false, false)

  defp finish_log_in(
         conn,
         %Accounts.Membership{account: %Accounts.Account{} = account} = membership,
         token,
         auth_method,
         mfa,
         registered?
       ) do
    return_to = return_path_for(conn, account)
    billing_intent = verified_billing_intent(get_session(conn, :billing_intent))
    attribution = MarketingAttribution.current(conn)
    :ok = record_sign_up(membership, registered?, attribution)

    conn
    |> RecentAccounts.put(%{slug: account.slug, name: account.name})
    |> put_workspace_session(account.id, token)
    |> maybe_restore_billing_intent(return_to, billing_intent)
    |> maybe_flash_just_registered(registered?)
    |> Analytics.track_authentication(membership, auth_method, mfa, registered?, attribution)
    |> redirect(to: return_to || billing_intent_path(billing_intent) || ~p"/app/#{account}")
  end

  defp record_sign_up(%Accounts.Membership{} = owner, true, attribution) do
    _result = Marketing.account_signed_up(owner, attribution)
    :ok
  end

  defp record_sign_up(_membership, false, _attribution), do: :ok

  # A return path the sign-in page or the workspace plug stored wins over a
  # stale pricing choice, unless that path is the billing selector the choice
  # was made for. Otherwise the renewal would clear the valid opaque intent
  # before the selector can consume it, so restore that one key after renewal.
  defp maybe_restore_billing_intent(conn, return_to, token) when is_binary(token) do
    if is_nil(return_to) or return_to == ~p"/app/billing/start",
      do: put_session(conn, :billing_intent, token),
      else: conn
  end

  defp maybe_restore_billing_intent(conn, _return_to, _token), do: conn

  defp billing_intent_path(token) when is_binary(token), do: ~p"/app/billing/start"
  defp billing_intent_path(_token), do: nil

  defp verified_billing_intent(token) do
    case BillingIntent.verify(token) do
      {:ok, _intent} -> token
      {:error, :invalid} -> nil
    end
  end

  defp maybe_flash_just_registered(conn, true),
    do: put_flash(conn, :info, "Welcome to emisar! Your workspace is ready.")

  defp maybe_flash_just_registered(conn, false), do: conn

  # A sign-in returns only to a page that names no workspace (it picks among the
  # browser's sessions itself) or to a page of the workspace it just signed in
  # to; anything else lands on that workspace. Only this server stores the
  # path, but it is checked against the router anyway.
  defp return_path_for(conn, %Accounts.Account{} = account) do
    with "/" <> _rest = path <- get_session(conn, :user_return_to),
         %URI{host: nil, path: "/" <> _ = route_path} <- URI.parse(path),
         %{} = route <- Phoenix.Router.route_info(EmisarWeb.Router, "GET", route_path, conn.host),
         true <- return_route?(route, account) do
      path
    else
      _ -> nil
    end
  end

  defp return_route?(%{path_params: %{"account_id_or_slug" => ref}}, account),
    do: ref in [account.slug, account.id]

  defp return_route?(%{pipe_through: pipelines}, _account), do: :require_signed_in in pipelines

  # The new entry replaces this workspace's entry, if any, and a seventh
  # workspace pushes out the oldest; both displaced tokens are revoked in this
  # request, so a copied cookie never keeps a credential this browser dropped.
  defp put_workspace_session(conn, account_id, token) do
    {replaced, others} = Enum.split_with(session_entries(conn), &(elem(&1, 0) == account_id))
    {evicted, kept} = Enum.split(others ++ [{account_id, token}], -@max_sessions)
    :ok = revoke_entries(conn, replaced, :replaced)
    :ok = revoke_entries(conn, evicted, :evicted)
    renew_session(conn, kept, browser_id(conn))
  end

  # A dead entry, or a session its workspace's policy no longer accepts, leaves
  # the cookie and its row is deleted. No renewal: nothing new is trusted.
  defp drop_workspace_session(conn, account_id) do
    {dropped, kept} = Enum.split_with(session_entries(conn), &(elem(&1, 0) == account_id))
    :ok = revoke_entries(conn, dropped, :dead_entry)
    store_entries(conn, kept)
  end

  defp revoke_entries(_conn, [], _revocation), do: :ok

  defp revoke_entries(conn, entries, revocation) do
    tokens = Enum.map(entries, fn {_account_id, token} -> token end)

    case Auth.revoke_session_tokens(tokens, revocation, RequestContext.from_conn(conn)) do
      :ok -> :ok
      {:error, reason} -> raise "could not revoke #{revocation} sessions: #{inspect(reason)}"
    end
  end

  # Nothing from before the sign-in or sign-out — a pending code, a ceremony
  # stash, the old CSRF token — survives into the renewed session; only the
  # entries and the browser id are carried.
  defp renew_session(conn, entries, browser_id) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> store_entries(entries)
    |> store_browser_id(browser_id)
  end

  defp store_entries(conn, []), do: delete_session(conn, :sessions)
  defp store_entries(conn, entries), do: put_session(conn, :sessions, entries)

  defp store_browser_id(conn, nil), do: conn
  defp store_browser_id(conn, browser_id), do: put_session(conn, :browser_id, browser_id)

  @email_code_request_keys ~w(magic_link_token_id magic_link_nonce magic_link_email
                              magic_link_expires_at magic_link_back_to)a

  @doc """
  Drop a pending email-code request's session state. A browser that starts
  another sign-in has abandoned it, and the session cookie needs the room.
  """
  def clear_email_code_request(conn),
    do: Enum.reduce(@email_code_request_keys, conn, &delete_session(&2, &1))

  # -- Sign-out -------------------------------------------------------

  @doc """
  Voluntary sign-out of this browser: the domain ends every session in the
  cookie and every session this browser minted, in every workspace, with one
  `user.signed_out` row per session in its own workspace; then the cookie is
  cleared, browser id included. Sockets disconnect after the commit. A
  rolled-back sign-out raises rather than reach the browser as a completed one.
  """
  def log_out_user(conn, to \\ ~p"/") do
    tokens = Enum.map(session_entries(conn), fn {_account_id, token} -> token end)
    context = RequestContext.from_conn(conn)

    case Auth.complete_browser_sign_out(tokens, browser_id(conn), context) do
      {:ok, members} ->
        conn
        |> Analytics.track_sign_out(members)
        |> renew_session([], nil)
        |> redirect(to: to)

      {:error, reason} ->
        raise "could not complete sign-out: #{inspect(reason)}"
    end
  end

  # -- Plugs ----------------------------------------------------------

  @doc """
  Used in `:browser`: assigns `:signed_in?`, whether the cookie holds any
  workspace session. No database read; pages that act on a session resolve it.
  """
  def fetch_session_entries(conn, _opts),
    do: assign(conn, :signed_in?, session_entries(conn) != [])

  @doc """
  Used in router on every `/app/:account_id_or_slug/...` route: resolves the
  workspace from the URL (unknown → 404) and authenticates this browser's entry
  for it, assigning `:current_auth`, `:current_membership`, `:current_account`
  and `:current_subject`. Without a live entry the request goes to that
  workspace's sign-in; a dead entry, or a session the workspace's `require_sso`
  no longer accepts, leaves the cookie first.
  """
  def fetch_workspace_session(conn, _opts) do
    account = fetch_url_account!(conn.path_params["account_id_or_slug"])

    with {_account_id, token} <- entry_for_account(conn, account.id),
         {:ok, session} <- Auth.fetch_session_by_token(token, account.id) do
      subject = Subject.for_session(session, RequestContext.from_conn(conn))

      case Accounts.account_compliance_for_session(session.membership.account, subject) do
        {:error, :sso_required} ->
          conn |> drop_workspace_session(account.id) |> send_to_workspace_sign_in(account)

        _compliant_or_mfa_owed ->
          conn
          |> assign(:current_auth, session)
          |> assign(:current_membership, session.membership)
          |> assign(:current_account, session.membership.account)
          |> assign(:current_subject, subject)
      end
    else
      nil ->
        send_to_workspace_sign_in(conn, account)

      {:error, :not_found} ->
        conn |> drop_workspace_session(account.id) |> send_to_workspace_sign_in(account)
    end
  end

  defp send_to_workspace_sign_in(conn, account) do
    conn
    |> put_flash(:error, "You must sign in to access that page.")
    |> maybe_store_return_to()
    |> redirect(to: ~p"/app/#{account}/sign_in")
    |> halt()
  end

  @doc """
  Used in router on the pages that name no workspace (`/app`, its shorthands,
  `/activate`, OAuth consent, the billing selector and the checkout return):
  assigns `:signed_in_sessions`, this browser's live sessions sorted by
  workspace name, each with its Member and workspace preloaded. Dead entries
  leave the cookie. With none, the request goes to `/sign_in`.
  """
  def require_signed_in(conn, _opts) do
    case live_workspace_sessions(conn) do
      {conn, []} ->
        conn
        |> put_flash(:error, "You must sign in to access that page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/sign_in")
        |> halt()

      {conn, sessions} ->
        assign(conn, :signed_in_sessions, sessions)
    end
  end

  defp live_workspace_sessions(conn) do
    entries = session_entries(conn)
    {:ok, sessions} = Auth.list_live_sessions(entries)
    live = MapSet.new(sessions, & &1.account_id)
    {kept, dead} = Enum.split_with(entries, &MapSet.member?(live, elem(&1, 0)))

    conn =
      if dead == [] do
        conn
      else
        :ok = revoke_entries(conn, dead, :dead_entry)
        store_entries(conn, kept)
      end

    {conn, Enum.sort_by(sessions, &String.downcase(&1.membership.account.name))}
  end

  @doc """
  Used in router on `/app/:account_id_or_slug/sign_in`: a browser already
  signed in to that workspace goes to it (or to the page that sent it to sign
  in); a dead entry for it leaves the cookie. An invitee finishing its
  invitation through the workspace's identity provider stays on the page.
  """
  def redirect_if_signed_in_to_workspace(conn, _opts) do
    with {:ok, account} <-
           Accounts.fetch_account_by_id_or_slug_including_disabled(
             conn.path_params["account_id_or_slug"]
           ),
         true <- invitation_sso_account_id(conn) != account.id,
         {_account_id, token} <- entry_for_account(conn, account.id) do
      case Auth.fetch_session_by_token(token, account.id) do
        {:ok, _session} ->
          to = return_path_for(conn, account) || ~p"/app/#{account}"
          conn |> delete_session(:user_return_to) |> redirect(to: to) |> halt()

        {:error, :not_found} ->
          drop_workspace_session(conn, account.id)
      end
    else
      _not_signed_in -> conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    # A long query string would overflow the ~4 KiB cookie and turn an
    # anonymous GET into a 500: keep the full path when it fits, else the bare
    # request path, else nothing.
    case Enum.find(
           [current_path(conn), conn.request_path],
           &(byte_size(&1) <= @return_to_max_bytes)
         ) do
      nil -> conn
      path -> put_session(conn, :user_return_to, path)
    end
  end

  defp maybe_store_return_to(conn), do: conn

  defp fetch_url_account!(account_ref) when is_binary(account_ref) do
    case Accounts.fetch_account_by_id_or_slug_including_disabled(account_ref) do
      {:ok, account} -> account
      {:error, :not_found} -> raise EmisarWeb.NotFoundError
    end
  end

  @doc """
  A `%Subject{}` for this browser's session in the workspace `account_ref` (id
  or slug) names, for a page or ceremony that names its workspace explicitly
  (OAuth consent, the billing selector, an SSO callback). Only an active
  workspace and a live entry for it qualify; anything else is `{:error,
  :not_found}`, the same as an unknown workspace.
  """
  def subject_for_account(%Plug.Conn{} = conn, account_ref) when is_binary(account_ref) do
    with {:ok, account} <- Accounts.fetch_account_by_id_or_slug(account_ref),
         {_account_id, token} <- entry_for_account(conn, account.id),
         {:ok, session} <- Auth.fetch_session_by_token(token, account.id) do
      {:ok, Subject.for_session(session, RequestContext.from_conn(conn))}
    else
      _ -> {:error, :not_found}
    end
  end

  def subject_for_account(%Plug.Conn{}, _account_ref), do: {:error, :not_found}

  @doc """
  The workspaces this browser is signed in to, from a LiveView session map,
  sorted by name. One query; dead entries are skipped (the next HTTP request
  removes them).
  """
  def signed_in_accounts(%{} = session) do
    {:ok, sessions} = Auth.list_live_sessions(session_entries(session))
    session_accounts(sessions)
  end

  defp session_accounts(sessions) do
    sessions
    |> Enum.map(& &1.membership.account)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc """
  The page's session no longer proves what it needs: back to the workspace,
  where the full page load re-decides (a dead entry goes to its sign-in).
  """
  def reauthenticate(%Phoenix.LiveView.Socket{} = socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, EmisarWeb.MfaErrors.message(:session_not_found))
    |> Phoenix.LiveView.redirect(to: ~p"/app/#{socket.assigns.current_account}")
  end

  # -- LiveView on_mount hooks ----------------------------------------

  # Flags that this render needs the full `app.js` (LiveSocket + hooks).
  # Attached to every LiveView via `EmisarWeb.live_view/0`, so the dead
  # render carries `@app_js?` up to `root.html.heex`; controller-rendered
  # marketing pages never set it and get the lean `marketing.js` instead.
  # A LIVE-navigated tab keeps executing the JS bundle it loaded until a FULL
  # page load — after a deploy, markup (fresh, over the socket) skews against
  # hooks (stale), which has shipped "the feature doesn't work" reports twice
  # (the time tooltip, the combobox corner fusion). When the connect params'
  # tracked statics no longer match the digest manifest, break out of live
  # navigation by redirecting to the SAME url — a full load with the new
  # bundle. No-op in dev/test (no digest manifest → static_changed? is false).
  def on_mount(:reload_stale_assets, _params, _session, socket) do
    if Phoenix.LiveView.static_changed?(socket) do
      {:cont,
       Phoenix.LiveView.attach_hook(
         socket,
         :stale_asset_reload,
         :handle_params,
         fn _params, uri, socket ->
           {:halt, Phoenix.LiveView.redirect(socket, external: uri)}
         end
       )}
    else
      {:cont, socket}
    end
  end

  def on_mount(:assign_app_bundle, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :app_js?, true)}
  end

  # Console activity + pageview tracking. The console is a LiveView app, so in-app
  # navigation happens over the websocket with no controller hit — the :browser
  # pageview plug only sees the dead render, which it skips for /app. This
  # attaches a `handle_params` lifecycle hook that records coarse membership
  # activity and fires `page_viewed` on the connected mount and every live
  # navigation; the `connected?` guard keeps the twice-running mount to one
  # event. UA captured at mount (connect-info is mount-only) and closed over.
  def on_mount(:track_pageviews, _params, _session, socket) do
    context = RequestContext.from_socket(socket)

    hook = fn _params, uri, socket ->
      if Phoenix.LiveView.connected?(socket) do
        touch_console_activity(socket.assigns[:current_subject])

        track_console_pageview(
          socket.assigns[:current_membership],
          socket.assigns[:current_account],
          uri,
          context
        )
      end

      {:cont, socket}
    end

    {:cont, Phoenix.LiveView.attach_hook(socket, :analytics_pageview, :handle_params, hook)}
  end

  # The workspace gate (IL-15) on every `/app/:account_id_or_slug` LiveView. The
  # workspace comes from the URL on every mount (unknown → 404) and the session
  # from this browser's entry for it; without a live one the socket goes to
  # that workspace's sign-in. A connected socket listens on its own session's
  # topic, so revoking exactly that session ends exactly its sockets, and leaves
  # on its own when the session expires.
  def on_mount(:ensure_authenticated, %{"account_id_or_slug" => account_ref}, session, socket) do
    account = fetch_url_account!(account_ref)
    {:ok, sessions} = Auth.list_live_sessions(session_entries(session))

    with %Auth.UserToken{} = auth <- Enum.find(sessions, &(&1.account_id == account.id)),
         {:ok, auth} <- watch_workspace_session(socket, auth) do
      {:cont, assign_workspace_session(socket, auth, sessions)}
    else
      _no_live_session ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}/sign_in")}
    end
  end

  # Account compliance for the MFA setup page: it is where a non-compliant
  # Member is sent, so it reads the posture instead of enforcing it. SSO
  # precedes MFA, so a session `require_sso` no longer accepts goes back to the
  # workspace, whose plug drops it, before it could enroll a factor.
  def on_mount(:assign_account_compliance, _params, _session, socket) do
    account = socket.assigns.current_account

    case Accounts.ensure_account_compliant(account, socket.assigns.current_subject) do
      {:error, :sso_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}")}

      result when result in [:ok, {:error, :mfa_required}] ->
        {:cont, Phoenix.Component.assign(socket, :account_compliance, result)}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end

  # Tenant pages enforce the workspace's SSO and MFA posture from one domain
  # decision. A session `require_sso` no longer accepts goes back to the
  # workspace, whose plug drops its entry; one that owes MFA goes to enrollment
  # or the current-factor challenge.
  def on_mount(:ensure_account_compliant, _params, _session, socket) do
    account = socket.assigns.current_account
    subject = socket.assigns.current_subject

    case Accounts.ensure_account_compliant(account, subject) do
      {:error, :sso_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}")}

      {:error, :mfa_required} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{account}/mfa_setup")}

      :ok ->
        {:cont, socket}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        raise EmisarWeb.NotFoundError
    end
  end

  # Tracks the account's approval, SSO-access, and pack-trust counts, plus the
  # fleet-offline alert, so all four nav cues stay live across every
  # authenticated LV without each one re-implementing the subscribe/handle_info
  # dance.
  #
  # First connect computes them + subscribes to the account's approvals, SSO,
  # packs, and runner-connections topics; `attach_hook`s then refresh whenever a
  # request is created/decided, a pack flips pending/resolved, or a runner connects/
  # disconnects. Broadcasts continue to the host LiveView's own handler;
  # only the hooks' private coalesced recompute ticks halt here.
  def on_mount(:track_pending_approvals, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket) and socket.assigns[:current_account] do
      account_id = socket.assigns.current_account.id
      subject = socket.assigns[:current_subject]

      if subject && Approvals.subject_can_view_approvals?(subject),
        do: Approvals.subscribe_account_approvals(account_id)

      if subject && Catalog.subject_can_view_packs?(subject),
        do: Catalog.subscribe_account_packs(account_id)

      if subject && Runners.subject_can_view_runners?(subject),
        do: Runners.subscribe_connections(account_id)

      if subject && SSO.subject_can_manage_sso?(subject),
        do: SSO.subscribe_account_link_requests(account_id)

      {:cont,
       socket
       |> ShellChrome.put(navigation_facts_for(subject))
       |> ShellChrome.put(
         support_channels: support_channels_for(subject),
         pending_approvals_count: approval_count_for(subject),
         pending_access_requests_count: access_request_count_for(subject),
         pending_packs_count: pack_pending_count_for(subject)
       )
       |> schedule_support_refresh()
       |> Phoenix.LiveView.attach_hook(
         :refresh_nav_support,
         :handle_info,
         &refresh_nav_support/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_pending_approvals,
         :handle_info,
         &refresh_pending_approvals/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_pending_packs,
         :handle_info,
         &refresh_pending_packs/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_pending_access_requests,
         :handle_info,
         &refresh_pending_access_requests/2
       )
       |> Phoenix.LiveView.attach_hook(
         :refresh_fleet_offline,
         :handle_info,
         &refresh_fleet_offline/2
       )}
    else
      # Dead mount (and the no-account edge): rest the nav cues at their empty
      # state — the connected mount above computes the real counts + subscribes,
      # so these four reads run once per live socket, not on the dead render too.
      {:cont,
       socket
       |> ShellChrome.put(navigation_facts_for(nil))}
    end
  end

  # A connected socket subscribes before it reads its session again, so a
  # revocation that lands between the mount's first read and the subscription
  # is not missed. The dead render subscribes to nothing.
  defp watch_workspace_session(socket, %Auth.UserToken{} = auth) do
    if Phoenix.LiveView.connected?(socket) do
      :ok = Accounts.subscribe_account_lifecycle(auth.account_id)
      :ok = Accounts.subscribe_account_team(auth.account_id)
      :ok = Auth.subscribe_session(auth)

      case Auth.fetch_current_session(
             Subject.for_session(auth, RequestContext.from_socket(socket))
           ) do
        {:ok, current} ->
          :ok = schedule_session_expiry(current)
          {:ok, current}

        {:error, :unauthorized} ->
          {:error, :session_ended}
      end
    else
      {:ok, auth}
    end
  end

  defp assign_workspace_session(socket, %Auth.UserToken{membership: membership} = auth, sessions) do
    subject = Subject.for_session(auth, RequestContext.from_socket(socket))

    socket
    |> Phoenix.Component.assign(:current_auth, auth)
    |> Phoenix.Component.assign(:current_membership, membership)
    |> Phoenix.Component.assign(:current_account, membership.account)
    |> Phoenix.Component.assign(:current_subject, subject)
    |> ShellChrome.put(switchable_accounts: session_accounts(sessions))
    |> Phoenix.LiveView.attach_hook(
      :ensure_slug_unchanged,
      :handle_params,
      &ensure_slug_unchanged/3
    )
    |> Phoenix.LiveView.attach_hook(:track_live_uri, :handle_params, &track_live_uri/3)
    |> Phoenix.LiveView.attach_hook(:account_lifecycle, :handle_info, &handle_account_lifecycle/2)
    |> Phoenix.LiveView.attach_hook(
      :membership_action_access,
      :handle_info,
      &refresh_membership_action_access/2
    )
    |> Phoenix.LiveView.attach_hook(:session_revoked, :handle_info, &handle_session_revoked/2)
    |> Phoenix.LiveView.attach_hook(:session_expiry, :handle_info, &handle_session_expiry/2)
  end

  defp track_live_uri(_params, uri, socket),
    do: {:cont, Phoenix.Component.assign(socket, :live_uri, uri)}

  # Revoking this exact session (sign-out, Profile, an admin, a policy change)
  # broadcasts on its topic. Another session's broadcast continues.
  defp handle_session_revoked(
         %Phoenix.Socket.Broadcast{event: "disconnect", topic: topic},
         socket
       ) do
    if topic == Auth.live_socket_topic(socket.assigns.current_auth.token),
      do: {:halt, end_workspace_session(socket)},
      else: {:cont, socket}
  end

  defp handle_session_revoked(_message, socket), do: {:cont, socket}

  defp handle_session_expiry({:workspace_session_expiry, session_id}, socket) do
    %Auth.UserToken{} = auth = socket.assigns.current_auth

    cond do
      session_id != auth.id ->
        {:halt, socket}

      DateTime.after?(Auth.session_expires_at(auth), DateTime.utc_now()) ->
        :ok = schedule_session_expiry(auth)
        {:halt, socket}

      true ->
        {:halt, end_workspace_session(socket)}
    end
  end

  defp handle_session_expiry(_message, socket), do: {:cont, socket}

  defp schedule_session_expiry(%Auth.UserToken{id: session_id} = auth) do
    wait_ms = DateTime.diff(Auth.session_expires_at(auth), DateTime.utc_now(), :millisecond)
    wait_ms = wait_ms |> max(0) |> min(@session_expiry_check_ms)
    _timer = Process.send_after(self(), {:workspace_session_expiry, session_id}, wait_ms)
    :ok
  end

  # A full page load re-decides: a dead entry leaves the cookie and the browser
  # lands on that workspace's sign-in, returning here afterwards.
  defp end_workspace_session(socket) do
    case socket.assigns[:live_uri] do
      uri when is_binary(uri) ->
        Phoenix.LiveView.redirect(socket, external: uri)

      nil ->
        Phoenix.LiveView.redirect(socket, to: ~p"/app/#{socket.assigns.current_account}")
    end
  end

  # Activity is a coarse operational hint the next navigation retries, never an
  # authorization dependency — so its outcome is dropped.
  defp touch_console_activity(%Subject{} = subject) do
    _result = Accounts.touch_membership_activity(subject)
    :ok
  end

  defp touch_console_activity(_subject), do: :ok

  defp track_console_pageview(%Accounts.Membership{} = membership, account, uri, context),
    do: Analytics.track_console_pageview(membership, account, uri, context)

  defp track_console_pageview(_membership, _account, _uri, _context), do: :ok

  defp handle_account_lifecycle(
         {:account_disabled, account_id},
         %{assigns: %{current_account: %{id: account_id}}} = socket
       ),
       do: {:halt, socket}

  defp handle_account_lifecycle(_message, socket), do: {:cont, socket}

  defp refresh_membership_action_access(
         {:list_changed, :team, "membership.runner_access_changed", membership_id},
         %{
           assigns: %{
             current_subject: %{membership_id: membership_id} = subject,
             current_membership: previous_membership
           }
         } = socket
       ) do
    with {:ok, %Auth.UserToken{membership: membership}} <- Auth.fetch_current_session(subject),
         true <- is_nil(membership.directory_authorization_pending_version),
         true <- is_nil(previous_membership.directory_authorization_pending_version),
         true <- membership.role == previous_membership.role,
         true <- Subject.effective_membership_role(membership) == subject.role do
      # Retain the original permission attenuation and session provenance. This
      # hook refreshes scope only; role/pending changes require a fresh mount.
      subject = Subject.rebuild(subject, membership, membership.account)

      {:cont,
       socket
       |> Phoenix.Component.assign(:current_membership, membership)
       |> Phoenix.Component.assign(:current_account, membership.account)
       |> Phoenix.Component.assign(:current_subject, subject)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/app/#{subject.account}")}
    end
  end

  defp refresh_membership_action_access(_message, socket), do: {:cont, socket}

  # Defense-in-depth for cross-slug `live_patch` (attached by :ensure_authenticated):
  # on_mount runs once, so a patch that changes the URL's account ref WITHOUT a
  # remount keeps the mount-time subject — the URL would say account B while the
  # socket is still scoped to A. No data crosses today (every context call uses
  # the mounted subject, not the ref), but assert the ref still resolves to the
  # mounted account on every handle_params and 404 on a mismatch rather than lean
  # on that invariant alone.
  defp ensure_slug_unchanged(%{"account_id_or_slug" => ref}, _uri, socket) do
    account = socket.assigns.current_account

    if ref == account.id or ref == account.slug do
      {:cont, socket}
    else
      raise EmisarWeb.NotFoundError
    end
  end

  defp ensure_slug_unchanged(_params, _uri, socket), do: {:cont, socket}

  defp refresh_pending_approvals({:approval_updated, _}, socket) do
    {:cont, schedule_badge_recompute(socket, :approvals)}
  end

  defp refresh_pending_approvals(
         {:list_changed, :team, "membership.runner_access_changed", membership_id},
         %{assigns: %{current_subject: %{membership_id: membership_id}}} = socket
       ),
       do: {:cont, schedule_badge_recompute(socket, :approvals)}

  defp refresh_pending_approvals({:recompute_nav_badge, :approvals}, socket) do
    {:halt,
     socket
     |> clear_badge_recompute(:approvals)
     |> ShellChrome.put(
       pending_approvals_count: approval_count_for(socket.assigns[:current_subject])
     )}
  end

  defp refresh_pending_approvals(_msg, socket), do: {:cont, socket}

  defp refresh_pending_access_requests({:sso_link_requests_changed, _account_id}, socket) do
    {:cont, schedule_badge_recompute(socket, :access_requests)}
  end

  defp refresh_pending_access_requests({:recompute_nav_badge, :access_requests}, socket) do
    {:halt,
     socket
     |> clear_badge_recompute(:access_requests)
     |> ShellChrome.put(
       pending_access_requests_count: access_request_count_for(socket.assigns[:current_subject])
     )}
  end

  defp refresh_pending_access_requests(_msg, socket), do: {:cont, socket}

  # Pack-trust badge counterpart. The count drives both the sidebar badge and
  # the dashboard banner (both read `@pending_packs_count`), and the message
  # CONTINUES to the host LiveView: halting it here left the Packs page — the
  # surface that gates dispatch authorization — showing "1 pending" beside a
  # stale list until someone reloaded, because its own handler never ran.
  defp refresh_pending_packs({:pack_trust_changed, _account_id}, socket) do
    {:cont, schedule_badge_recompute(socket, :packs)}
  end

  defp refresh_pending_packs({:recompute_nav_badge, :packs}, socket) do
    {:halt,
     socket
     |> clear_badge_recompute(:packs)
     |> ShellChrome.put(
       pending_packs_count: pack_pending_count_for(socket.assigns[:current_subject])
     )}
  end

  defp refresh_pending_packs(_msg, socket), do: {:cont, socket}

  defp schedule_badge_recompute(socket, badge) do
    pending = socket.assigns[:pending_badge_recomputes] || MapSet.new()

    if MapSet.member?(pending, badge) do
      socket
    else
      Process.send_after(self(), {:recompute_nav_badge, badge}, 500)
      Phoenix.Component.assign(socket, :pending_badge_recomputes, MapSet.put(pending, badge))
    end
  end

  defp clear_badge_recompute(socket, badge) do
    pending = socket.assigns[:pending_badge_recomputes] || MapSet.new()
    Phoenix.Component.assign(socket, :pending_badge_recomputes, MapSet.delete(pending, badge))
  end

  # Heartbeats update Presence metadata without changing fleet connectivity.
  # Recompute the nav alert only for join-only or leave-only topology changes;
  # host LiveViews still receive the diff to patch their own visible state.
  defp refresh_fleet_offline(%{event: "presence_diff"} = event, socket) do
    change = Runners.normalize_connection_change(event)

    if Runners.connection_topology_changed?(change) do
      {:cont, schedule_fleet_recompute(socket)}
    else
      {:cont, socket}
    end
  end

  defp refresh_fleet_offline(:recompute_fleet_offline, socket) do
    subject = socket.assigns[:current_subject]

    {:halt,
     socket
     |> ShellChrome.put(navigation_facts_for(subject))
     |> Phoenix.Component.assign(:fleet_recompute_scheduled?, false)}
  end

  defp refresh_fleet_offline(_msg, socket), do: {:cont, socket}

  defp schedule_fleet_recompute(socket) do
    if socket.assigns[:fleet_recompute_scheduled?] do
      socket
    else
      Process.send_after(self(), :recompute_fleet_offline, 500)
      Phoenix.Component.assign(socket, :fleet_recompute_scheduled?, true)
    end
  end

  defp approval_count_for(nil), do: 0
  defp approval_count_for(subject), do: Approvals.count_pending_approval_requests(subject)

  defp support_channels_for(%Subject{account: account} = subject) do
    case Billing.support_channels(account, subject) do
      {:ok, channels} -> channels
      {:error, _} -> %{email?: false, slack_url: nil}
    end
  end

  defp support_channels_for(_), do: %{email?: false, slack_url: nil}

  # Billing refreshes this projection alongside its summary. Other mounted
  # pages need a bounded local read too: plan deadlines and staff link changes
  # must not leave a stale destination in the sidebar indefinitely.
  defp schedule_support_refresh(%{view: EmisarWeb.BillingLive} = socket), do: socket

  defp schedule_support_refresh(socket) do
    attempt = make_ref()
    Process.send_after(self(), {:refresh_nav_support, attempt}, 60_000)
    Phoenix.Component.assign(socket, :support_refresh, attempt)
  end

  defp refresh_nav_support({:refresh_nav_support, attempt}, socket) do
    if socket.assigns[:support_refresh] == attempt do
      {:halt,
       socket
       |> ShellChrome.put(
         support_channels: support_channels_for(socket.assigns[:current_subject])
       )
       |> schedule_support_refresh()}
    else
      {:halt, socket}
    end
  end

  defp refresh_nav_support(_message, socket), do: {:cont, socket}

  defp access_request_count_for(nil), do: 0
  defp access_request_count_for(subject), do: SSO.count_pending_link_requests(subject)

  # Pack-decision badge counterpart: computed at connected mount and kept live
  # by `refresh_pending_packs` on the account's packs topic. Counts every
  # version in current pack access awaiting a decision — pending trust reviews
  # AND retired-blocked trusted versions.
  defp pack_pending_count_for(nil), do: 0

  defp pack_pending_count_for(subject),
    do: Catalog.count_pack_versions_needing_decision(subject)

  defp navigation_facts_for(nil) do
    %{fleet_all_offline?: false, no_agents?: false, onboarding_incomplete?: false}
  end

  # One fleet aggregate and one key-existence read own all three navigation
  # cues. The old helpers repeated both existence queries to derive mutually
  # exclusive dots from the same two facts.
  defp navigation_facts_for(subject) do
    {has_runners?, fleet_all_offline?} =
      case Runners.fetch_fleet_status(subject) do
        {:ok, status} ->
          {status.counts.active > 0, :no_runners_online in status.reasons}

        {:error, _reason} ->
          {false, false}
      end

    agent_missing? = ApiKeys.no_agents?(subject)

    %{
      fleet_all_offline?: fleet_all_offline?,
      no_agents?: agent_missing? and has_runners?,
      onboarding_incomplete?: agent_missing? and not has_runners?
    }
  end
end

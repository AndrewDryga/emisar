defmodule EmisarWeb.Analytics do
  @moduledoc """
  Web boundary for product analytics — the conn-aware layer over
  `Emisar.Analytics`. emisar tracks **without analytics cookies**: an anonymous
  visitor is a weekly-rotating salted hash of IP + User-Agent
  (`Emisar.Crypto.anonymous_visitor_id/1` — the Plausible/Fathom model: no
  client storage, unlinkable across weeks), and an authenticated user is their
  `user.id` (from the necessary auth session). The only cookie the site sets is
  the strictly-necessary CSRF/session cookie — never an analytics identifier.

  The data is first-party and never sold or shared, so there is no DNT/GPC
  opt-out gate (those headers signal opt-out of *sale/sharing*, which we don't
  do — being cookieless is the privacy story). This module owns the
  request-derived bits Mixpanel can't see for a server-to-server call: the
  `$device:` identity + anon→user merge, the client IP (→ geo), the UA-parsed
  browser/OS/device, and the URL/referrer. Domain value-moment events live in
  `Emisar.Analytics.Events`.
  """

  import Plug.Conn

  alias Emisar.Analytics
  alias Emisar.Crypto

  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  # Console detail-page id segments to collapse so `path` doesn't explode.
  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  # -- Funnel events ---------------------------------------------------

  @doc "Fire a `page_viewed` for the current (marketing/auth) request."
  def track_pageview(conn) do
    {distinct_id, opts} = identity(conn)

    props =
      Map.merge(
        %{"path" => conn.request_path, "authenticated" => authenticated?(conn)},
        current_utm(conn)
      )

    emit(conn, "page_viewed", distinct_id, props, opts)
    :ok
  end

  @doc "Fire a marketing `lead_captured` (footer subscribe)."
  def track_lead_captured(conn, source) do
    {distinct_id, opts} = identity(conn)
    props = Map.merge(%{"source" => source}, current_utm(conn))
    emit(conn, "lead_captured", distinct_id, props, opts)
    :ok
  end

  @doc """
  Fire a `page_viewed` for a console (LiveView) navigation. The console is a
  LiveView app, so its in-app navigation never hits a controller — this is
  driven by the `:track_pageviews` `on_mount` hook (`handle_params`), with the
  `uri` + the mount-captured `%RequestContext{}`. Always authenticated
  (distinct_id = the user id). The path is normalized (account slug + detail
  UUIDs collapsed to `/app/:account/…/:id`) so console pages aggregate.
  """
  def track_console_pageview(user, account, uri, context) do
    %URI{path: path} = URI.parse(uri)
    ua = EmisarWeb.UserAgent.parse(context.user_agent)

    props =
      %{
        "path" => normalize_console_path(path),
        "authenticated" => true,
        "$current_url" => uri,
        "$browser" => ua.browser,
        "$browser_version" => ua.browser_version,
        "$os" => ua.os,
        "$device" => ua.device
      }
      |> put_account(account)

    Analytics.track("page_viewed", user.id, props, user_id: user.id, ip: context.ip_address)
    set_account_group(account)
  end

  # -- Identity transitions (called from UserAuth) ---------------------

  @doc """
  On a completed sign-in: refresh the user profile, then track
  `sign_up_completed` (a brand-new registration) or `signed_in`, sending the
  same-week anonymous `device_id` + the `user_id` so Mixpanel merges the
  pre-signup journey to the user. Returns `conn` (pipeline-friendly).
  """
  def track_authentication(conn, user, auth_method, mfa, registered?) do
    method = to_string(auth_method)

    Analytics.set_people(user.id, %{
      "$name" => user.full_name,
      "$email" => user.email,
      "auth_method" => method
    })

    event = if registered?, do: "sign_up_completed", else: "signed_in"
    props = Map.merge(%{"auth_method" => method, "mfa" => mfa}, current_utm(conn))
    emit(conn, event, user.id, props, device_id: device_id(conn), user_id: user.id)
    conn
  end

  @doc "On logout: track `signed_out` for the still-current user. Returns `conn`."
  def track_sign_out(conn) do
    user = conn.assigns[:current_user]

    if user do
      emit(conn, "signed_out", user.id, %{}, user_id: user.id)
    end

    conn
  end

  # -- internals -------------------------------------------------------

  # distinct_id + merge opts. Anonymous = the cookieless weekly device hash,
  # `$device:`-prefixed so Mixpanel treats it as a mergeable device (not a
  # separate identified user). Identified = the user id (+ the device hash, so
  # the first post-login event merges the same-week anonymous journey).
  defp identity(conn) do
    case conn.assigns[:current_user] do
      nil ->
        id = device_id(conn)
        {"$device:" <> id, [device_id: id]}

      user ->
        {user.id, [user_id: user.id, device_id: device_id(conn)]}
    end
  end

  # The cookieless, weekly-rotating anonymous id for this request.
  defp device_id(conn), do: Crypto.anonymous_visitor_id(fingerprint(conn))

  defp fingerprint(conn), do: "#{client_ip(conn)}|#{user_agent(conn)}"

  # Every web event carries the enrichment Mixpanel can't derive from a
  # server-to-server call: the client IP (→ $city/$region/country geo), the
  # UA-parsed browser/OS/device, and the URL/referrer. Nils are dropped by track.
  defp emit(conn, event, distinct_id, props, opts) do
    props = Map.merge(request_props(conn), props)
    opts = Keyword.put_new(opts, :ip, client_ip(conn))
    Analytics.track(event, distinct_id, props, opts)
  end

  defp request_props(conn) do
    ua = EmisarWeb.UserAgent.parse(user_agent(conn))

    %{
      "$browser" => ua.browser,
      "$browser_version" => ua.browser_version,
      "$os" => ua.os,
      "$device" => ua.device,
      "$current_url" => current_url(conn),
      "$referrer" => List.first(get_req_header(conn, "referer")),
      "$referring_domain" => referring_domain(conn)
    }
  end

  # This request's campaign params — sent on each event; Mixpanel derives
  # first-touch per distinct_id from the (same-week, merged) event stream.
  defp current_utm(conn) do
    conn = fetch_query_params(conn)
    Map.take(conn.query_params, @utm_params)
  end

  # The real client IP (x-forwarded-for-aware), reusing the canonical extractor —
  # Mixpanel resolves geo from it and does not store the raw IP as a property.
  defp client_ip(conn), do: EmisarWeb.RequestContext.from_conn(conn).ip_address

  defp user_agent(conn), do: List.first(get_req_header(conn, "user-agent"))

  defp current_url(conn), do: "#{conn.scheme}://#{conn.host}#{conn.request_path}"

  defp authenticated?(conn), do: conn.assigns[:current_user] != nil

  defp referring_domain(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).host
      _ -> nil
    end
  end

  # Console detail pages embed the account slug + run/runner UUIDs, which would
  # explode `path` cardinality (every run id = a unique page). Normalize to
  # templates so they aggregate: /app/acme/runs/<uuid> → /app/:account/runs/:id.
  defp normalize_console_path(path) do
    case String.split(path, "/") do
      ["", "app", _account | rest] ->
        Enum.join(["", "app", ":account" | Enum.map(rest, &mask_id/1)], "/")

      _ ->
        path
    end
  end

  defp mask_id(segment) do
    if Regex.match?(@uuid_re, segment), do: ":id", else: segment
  end

  # `account_id` rides every console event so Mixpanel Group Analytics can roll
  # usage up by account (the group key); the group PROFILE (name) is set
  # alongside. Both no-op without the paid add-on (`set_group` is gated).
  defp put_account(props, %{id: id}), do: Map.put(props, "account_id", id)
  defp put_account(props, _), do: props

  defp set_account_group(%{id: id, name: name}),
    do: Analytics.set_group("account_id", id, %{"$name" => name})

  defp set_account_group(_), do: :ok
end

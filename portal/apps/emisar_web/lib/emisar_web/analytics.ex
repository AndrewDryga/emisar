defmodule EmisarWeb.Analytics do
  @moduledoc """
  Web boundary for product analytics — the conn/session-aware layer over
  `Emisar.Analytics`. It owns the server-side identity bits that need the
  HTTP request: the anonymous **device id** (carried in the *existing*
  session cookie, so no new cookie ships), first-touch UTM/referrer
  capture, the DNT / Global-Privacy-Control opt-out gate, the
  marketing/funnel `page_viewed`, and translating a sign-in into a
  Mixpanel identify + anonymous→user merge.

  The domain value-moment events live in `Emisar.Analytics.Events`; this
  module is only the funnel + identity surface (the `EmisarWeb`
  counterpart to `EmisarWeb.RequestContext`).
  """

  import Plug.Conn

  alias Emisar.Analytics

  @device_id_key :analytics_device_id
  @first_touch_key :analytics_first_touch
  @utm_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  # -- Opt-out + anonymous id (plug side) ------------------------------

  @doc "False when the request carries `DNT: 1` or `Sec-GPC: 1` — no tracking, no id."
  def tracking_allowed?(conn) do
    get_req_header(conn, "dnt") != ["1"] and get_req_header(conn, "sec-gpc") != ["1"]
  end

  @doc """
  Get-or-create the anonymous device id in the session — the merge anchor
  that stitches the pre-signup journey to the user. No-op when opted out.
  """
  def ensure_device_id(conn) do
    cond do
      not tracking_allowed?(conn) -> conn
      get_session(conn, @device_id_key) -> conn
      true -> put_session(conn, @device_id_key, Ecto.UUID.generate())
    end
  end

  @doc "Capture first-touch UTM params + external referrer host once, into the session."
  def capture_first_touch(conn) do
    first_touch = build_first_touch(conn)

    if tracking_allowed?(conn) and is_nil(get_session(conn, @first_touch_key)) and
         map_size(first_touch) > 0 do
      put_session(conn, @first_touch_key, first_touch)
    else
      conn
    end
  end

  @doc "Fire a `page_viewed` for the current (marketing/auth) request."
  def track_pageview(conn) do
    if tracking_allowed?(conn) do
      {distinct_id, opts} = identity(conn)

      props =
        Map.merge(
          %{"path" => conn.request_path, "authenticated" => authenticated?(conn)},
          first_touch(conn)
        )

      emit(conn, "page_viewed", distinct_id, props, opts)
    end

    :ok
  end

  @doc "Fire a marketing `lead_captured` (footer subscribe) — anonymous, device-scoped."
  def track_lead_captured(conn, source) do
    if tracking_allowed?(conn) do
      {distinct_id, opts} = identity(conn)
      props = Map.merge(%{"source" => source}, first_touch(conn))
      emit(conn, "lead_captured", distinct_id, props, opts)
    end

    :ok
  end

  # -- Identity transitions (called from UserAuth) ---------------------

  @doc """
  Pre-login analytics snapshot (device id + first touch), captured BEFORE
  `renew_session/1` wipes the session. Pass it to `track_authentication/5`.
  """
  def capture_pre_login(conn) do
    %{device_id: get_session(conn, @device_id_key), first_touch: first_touch(conn)}
  end

  @doc """
  On a completed sign-in: refresh the user profile, then track
  `sign_up_completed` (a brand-new registration) or `signed_in`, sending
  the anonymous `device_id` + `user_id` so Mixpanel merges the pre-signup
  journey to the user. Returns `conn` (pipeline-friendly).
  """
  def track_authentication(conn, user, auth_method, mfa, pre_login) do
    if tracking_allowed?(conn) do
      method = to_string(auth_method)

      Analytics.set_people(user.id, %{
        "$name" => user.full_name,
        "$email" => user.email,
        "auth_method" => method
      })

      event = if registered?(conn), do: "sign_up_completed", else: "signed_in"
      props = Map.merge(%{"auth_method" => method, "mfa" => mfa}, pre_login.first_touch)
      emit(conn, event, user.id, props, device_id: pre_login.device_id, user_id: user.id)
    end

    conn
  end

  @doc "On logout: track `signed_out` for the still-current user. Returns `conn`."
  def track_sign_out(conn) do
    user = conn.assigns[:current_user]

    if tracking_allowed?(conn) and user do
      emit(conn, "signed_out", user.id, %{}, user_id: user.id)
    end

    conn
  end

  # -- internals -------------------------------------------------------

  # The sign-up form posts `?_action=registered`; pattern-matched (not
  # `conn.params[...]`) so it stays safe when params are unfetched.
  defp registered?(%{params: %{"_action" => "registered"}}), do: true
  defp registered?(_conn), do: false

  # distinct_id + merge opts for an anonymous-or-identified request.
  defp identity(conn) do
    case conn.assigns[:current_user] do
      nil ->
        device_id = get_session(conn, @device_id_key) || "anonymous"
        # The `$device:` prefix marks this as an anonymous device, not an
        # identified user — without it Mixpanel counts every device as its own
        # person and the post-login merge can't stitch the pre-signup journey.
        {"$device:" <> device_id, [device_id: device_id]}

      user ->
        {user.id, [user_id: user.id, device_id: get_session(conn, @device_id_key)]}
    end
  end

  # Every web event carries the enrichment Mixpanel can't derive from a
  # server-to-server call: the client IP (→ $city/$region/country geo), the
  # UA-parsed browser/OS/device, and the URL/referrer. Nils are dropped by track.
  defp emit(conn, event, distinct_id, props, opts) do
    props = Map.merge(request_props(conn), props)
    opts = Keyword.put_new(opts, :ip, client_ip(conn))
    Analytics.track(event, distinct_id, props, opts)
  end

  defp request_props(conn) do
    ua = EmisarWeb.UserAgent.parse(List.first(get_req_header(conn, "user-agent")))

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

  # The real client IP (x-forwarded-for-aware), reusing the canonical extractor —
  # Mixpanel resolves geo from it and does not store the raw IP as a property.
  defp client_ip(conn), do: EmisarWeb.RequestContext.from_conn(conn).ip_address

  defp current_url(conn), do: "#{conn.scheme}://#{conn.host}#{conn.request_path}"

  defp authenticated?(conn), do: conn.assigns[:current_user] != nil

  defp first_touch(conn), do: get_session(conn, @first_touch_key) || %{}

  defp build_first_touch(conn) do
    conn = fetch_query_params(conn)
    utm = Map.take(conn.query_params, @utm_params)

    case referrer_host(conn) do
      nil -> utm
      host -> Map.put(utm, "referrer_host", host)
    end
  end

  # Only an EXTERNAL referrer is acquisition signal — our own host is internal nav.
  defp referrer_host(conn) do
    with [referer | _] <- get_req_header(conn, "referer"),
         %URI{host: host} when is_binary(host) and host != conn.host <- URI.parse(referer) do
      host
    else
      _ -> nil
    end
  end

  # The referrer's domain whatever it is (internal page-to-page included), for
  # Mixpanel's `$referring_domain`; `referrer_host/1` (external-only) drives
  # first-touch acquisition.
  defp referring_domain(conn) do
    case get_req_header(conn, "referer") do
      [referer | _] -> URI.parse(referer).host
      _ -> nil
    end
  end
end

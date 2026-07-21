defmodule EmisarWeb.AnalyticsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use EmisarWeb.ConnCase, async: false

  @browser_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " <>
                        "AppleWebKit/537.36 (KHTML, like Gecko) " <>
                        "Chrome/126.0.0.0 Safari/537.36"

  setup %{conn: conn} do
    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Application.delete_env(:emisar, :analytics_test_pid)
    end)

    {:ok, conn: put_req_header(conn, "user-agent", @browser_user_agent)}
  end

  describe "pageview plug" do
    test "a marketing GET fires page_viewed with a cookieless $device: id", %{conn: conn} do
      conn = get(conn, ~p"/pricing")

      # No browser identifier is stored; campaign metadata is only written
      # when a UTM exists.
      refute Plug.Conn.get_session(conn, :analytics_device_id)
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["path"] == "/pricing"
      assert props["authenticated"] == false
      # Anonymous distinct_id is the $device:-prefixed weekly hash, so Mixpanel
      # treats it as a mergeable device, not a separate identified user.
      assert "$device:" <> _ = props["distinct_id"]
    end

    test "the same visitor gets a stable id across requests — no cookie needed", %{conn: conn} do
      base = put_req_header(conn, "user-agent", "Mozilla/5.0 (X11; Linux) Firefox/121.0")

      get(base, ~p"/pricing")
      assert_receive {:mixpanel_track, [%{"properties" => %{"distinct_id" => first}}]}
      get(base, ~p"/security")
      assert_receive {:mixpanel_track, [%{"properties" => %{"distinct_id" => second}}]}

      # Same IP + UA (same week) → same weekly hash → countable as one visitor,
      # stitched on login, all without a client-stored identifier.
      assert first == second
      assert "$device:" <> _ = first
    end

    test "events carry geo (ip), UA-derived browser/OS, and the URL", %{conn: conn} do
      ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
          "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

      conn |> put_req_header("user-agent", ua) |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"properties" => props}]}
      assert props["ip"]
      assert props["$browser"] == "Chrome"
      assert props["$os"] == "Windows"
      assert props["$current_url"] =~ "/pricing"
    end

    test "credential-bearing paths and referrers are redacted", %{conn: conn} do
      conn
      |> put_req_header(
        "referer",
        "https://emisar.dev/accept_invitation/referrer-secret?source=email"
      )
      |> get("/accept_invitation/request-secret")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["path"] == "/accept_invitation/:token"
      assert props["$current_url"] == "http://www.example.com/accept_invitation/:token"
      assert props["$referrer"] == "https://emisar.dev/accept_invitation/:token"
      refute inspect(props) =~ "request-secret"
      refute inspect(props) =~ "referrer-secret"
    end

    test "referrer query strings are never sent", %{conn: conn} do
      conn
      |> put_req_header(
        "referer",
        "https://emisar.dev/sign_in/sso/callback?code=credential&state=handoff"
      )
      |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["$referrer"] == "https://emisar.dev/sign_in/sso/callback"
      refute inspect(props) =~ "credential"
      refute inspect(props) =~ "handoff"
    end

    test "tracks regardless of DNT / GPC (server-side first-party — nothing to opt out of)",
         %{conn: conn} do
      conn |> put_req_header("dnt", "1") |> put_req_header("sec-gpc", "1") |> get(~p"/pricing")
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "first-touch UTM persists across subsequent pageviews", %{conn: conn} do
      conn =
        get(
          conn,
          "/?utm_source=x&utm_medium=paid_social&utm_campaign=launch&utm_term=mcp&utm_content=ad_1"
        )

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
      assert props["utm_term"] == "mcp"
      assert props["utm_content"] == "ad_1"

      conn
      |> recycle()
      |> put_req_header("user-agent", @browser_user_agent)
      |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
      assert props["utm_term"] == "mcp"
      assert props["utm_content"] == "ad_1"
    end

    test "first-touch UTM is byte-bounded and is not replaced later in the session", %{conn: conn} do
      long_campaign = String.duplicate("界", 100)
      query = URI.encode_query(%{"utm_source" => "first", "utm_campaign" => long_campaign})
      conn = get(conn, "/?#{query}")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      conn
      |> recycle()
      |> put_req_header("user-agent", @browser_user_agent)
      |> get("/pricing?utm_source=second&utm_campaign[bad]=nested")

      assert_receive {:mixpanel_track, [%{"properties" => props}]}
      assert props["utm_source"] == "first"
      assert props["utm_campaign"] == String.duplicate("界", 85)
      assert byte_size(props["utm_campaign"]) == 255
    end

    test "an in-app browser without a Safari token still fires page_viewed", %{conn: conn} do
      user_agent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) " <>
          "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

      conn |> put_req_header("user-agent", user_agent) |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "health probes never fire page_viewed", %{conn: conn} do
      get(conn, ~p"/healthz")
      get(conn, ~p"/readyz")

      refute_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "automated and non-browser fetches do not fire page_viewed", %{conn: conn} do
      user_agents = [
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
        "Mozilla/5.0 Twitterbot/1.0",
        "Mozilla/5.0 HeadlessChrome/126.0.0.0 Safari/537.36",
        "Mozilla/5.0 GoogleStackdriverMonitoring-UptimeChecks/1.0",
        "Mozilla/5.0 facebookexternalhit/1.1",
        "Mozilla/5.0 WhatsApp/2.23.20",
        "curl/8.5.0"
      ]

      for user_agent <- user_agents do
        conn |> put_req_header("user-agent", user_agent) |> get(~p"/pricing")
      end

      refute_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "a request without a user agent does not fire page_viewed", %{conn: conn} do
      conn |> delete_req_header("user-agent") |> get(~p"/pricing")

      refute_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "the console (/app) is not pageview-tracked", %{conn: conn} do
      # Unauthenticated /app redirects (not a 200 html render), so no page_viewed.
      conn |> get(~p"/app")
      refute_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end
  end

  test "footer subscribe carries the session's first-touch attribution", %{conn: conn} do
    conn = get(conn, "/?utm_source=x&utm_medium=paid_social&utm_campaign=launch")
    assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

    email = "lead-#{System.unique_integer([:positive])}@example.com"
    conn |> recycle() |> post(~p"/subscribe", %{"email" => email, "source" => "footer"})

    assert_receive {:mixpanel_track, [%{"event" => "lead_captured", "properties" => props}]}
    assert props["source"] == "footer"
    assert props["utm_source"] == "x"
    assert props["utm_medium"] == "paid_social"
    assert props["utm_campaign"] == "launch"
  end

  describe "identity" do
    setup do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "id-#{System.unique_integer([:positive])}@example.com",
          full_name: "Jane Op"
        })

      {:ok, user: Fixtures.Users.confirm_user(user)}
    end

    test "a magic-link sign-in sets the profile and fires signed_in with the user id", %{
      conn: conn,
      user: user
    } do
      # Drive the real passwordless flow: request the link, pull token_id + the
      # 6-character secret from the email, then confirm from the same browser (the
      # nonce cookie rides `recycle`). `log_in_user` fires the analytics event.
      conn = get(conn, "/?utm_source=x&utm_medium=paid_social&utm_campaign=launch")
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      conn =
        conn
        |> recycle()
        |> post(~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      conn = conn |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{secret}")
      refute get_session(conn, :analytics_campaign_attribution)

      assert_receive {:mixpanel_engage, [%{"$distinct_id" => id, "$set" => set} = update]}

      assert id == user.id
      assert set["$email"] == user.email
      assert set["$name"] == "Jane Op"
      refute Map.has_key?(update, "$set_once")

      assert_receive {:mixpanel_track, [%{"event" => "signed_in", "properties" => props}]}
      assert props["distinct_id"] == user.id
      assert props["$user_id"] == user.id
      assert props["auth_method"] == "magic_link"
      assert props["mfa"] == false
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
      refute Map.has_key?(props, "$current_url")
    end

    test "a completed registration carries first-touch attribution", %{conn: conn} do
      user = Fixtures.Users.create_user(confirmed?: false)
      conn = get(conn, "/?utm_source=x&utm_medium=paid_social&utm_campaign=launch")
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      conn =
        conn
        |> recycle()
        |> post(~p"/sign_in/magic/start", %{
          "user" => %{"email" => user.email},
          "registration_handoff" => EmisarWeb.RegistrationHandoff.sign(user.id)
        })

      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      conn |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{secret}")

      assert_receive {:mixpanel_engage, [set_update, %{"$set_once" => set_once}]}
      assert set_update["$set"]["$email"] == user.email
      assert set_once["initial_utm_source"] == "x"
      assert set_once["initial_utm_medium"] == "paid_social"
      assert set_once["initial_utm_campaign"] == "launch"

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_completed", "properties" => props}]}

      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
    end

    test "logout fires signed_out", %{conn: conn, user: user} do
      conn |> log_in_user(user) |> delete(~p"/sign_out")

      assert_receive {:mixpanel_track, [%{"event" => "signed_out", "properties" => props}]}
      assert props["distinct_id"] == user.id
    end
  end

  describe "console (LiveView) pageviews" do
    test "a console mount fires page_viewed — authenticated, with the path", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn)
      {:ok, _lv, _html} = live(conn, ~p"/app/#{account.slug}")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["authenticated"] == true
      assert props["distinct_id"] == user.id
      assert props["$user_id"] == user.id
      # Path is normalized — the account slug collapses to :account so console
      # pages aggregate (UUID detail segments collapse to :id the same way).
      assert props["path"] == "/app/:account"
      # The client IP is forwarded (test peer, since no x-forwarded-for header).
      assert props["ip"]
      # account_id rides every console event so Group Analytics can roll usage
      # up by account (the group key).
      assert props["account_id"] == account.id
    end
  end
end

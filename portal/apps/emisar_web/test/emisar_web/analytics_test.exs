defmodule EmisarWeb.AnalyticsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use EmisarWeb.ConnCase, async: false

  @browser_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " <>
                        "AppleWebKit/537.36 (KHTML, like Gecko) " <>
                        "Chrome/126.0.0.0 Safari/537.36"

  setup %{conn: conn} do
    Emisar.Config.put_override(:emisar, :mixpanel_enabled, true)
    Emisar.Config.put_override(:emisar, :analytics_test_pid, self())

    {:ok, conn: put_req_header(conn, "user-agent", @browser_user_agent)}
  end

  describe "pageview plug" do
    test "a marketing GET fires page_viewed with a cookieless $device: id", %{conn: conn} do
      conn = get(conn, ~p"/pricing")

      # No browser identifier is stored; attribution metadata is written only
      # when a UTM or external referrer exists.
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
      assert props["$initial_referrer"] == "https://emisar.dev/"
      assert props["$initial_referring_domain"] == "emisar.dev"
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

    test "first external referrer persists without its path or credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header(
          "referer",
          "https://partner.example/articles/sandbox?invite=private-token#offer"
        )
        |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["$initial_referrer"] == "https://partner.example/"
      assert props["$initial_referring_domain"] == "partner.example"

      stored = get_session(conn, :analytics_campaign_attribution)
      assert stored["$initial_referrer"] == "https://partner.example/"
      assert stored["$initial_referring_domain"] == "partner.example"
      refute inspect(stored) =~ "articles"
      refute inspect(stored) =~ "private-token"

      conn
      |> recycle()
      |> put_req_header("user-agent", @browser_user_agent)
      |> put_req_header("referer", "https://later.example/path?secret=other")
      |> get("/security?utm_source=partner&utm_campaign=launch")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["$initial_referrer"] == "https://partner.example/"
      assert props["$initial_referring_domain"] == "partner.example"
      assert props["utm_source"] == "partner"
      assert props["utm_campaign"] == "launch"
    end

    test "first external referrer values are byte-bounded", %{conn: conn} do
      long_host =
        [70, 70, 70, 70]
        |> Enum.map_join(".", &String.duplicate("a", &1))

      conn =
        conn
        |> put_req_header("referer", "https://#{long_host}/private-path")
        |> get(~p"/pricing")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      stored = get_session(conn, :analytics_campaign_attribution)
      assert byte_size(stored["$initial_referrer"]) == 255
      # The whole map keeps to its 512-byte share of the session cookie, so the
      # equally long domain is left out.
      refute Map.has_key?(stored, "$initial_referring_domain")
      refute inspect(stored) =~ "private-path"
    end

    test "a later campaign never evicts the first referrer; it takes only the room left", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("referer", "https://partner.example/")
        |> get(~p"/pricing")

      campaign = String.duplicate("c", 255)

      query =
        URI.encode_query(%{
          "utm_source" => "partner",
          "utm_medium" => "email",
          "utm_campaign" => campaign,
          "utm_content" => String.duplicate("d", 172)
        })

      conn =
        conn
        |> recycle()
        |> put_req_header("user-agent", @browser_user_agent)
        |> get("/security?" <> query)

      conn =
        conn
        |> recycle()
        |> put_req_header("user-agent", @browser_user_agent)
        |> put_req_header("referer", "https://t.co/")
        |> get(~p"/pricing")

      stored = get_session(conn, :analytics_campaign_attribution)
      assert stored["$initial_referrer"] == "https://partner.example/"
      assert stored["$initial_referring_domain"] == "partner.example"
      assert stored["utm_campaign"] == campaign
      refute Map.has_key?(stored, "utm_content")
    end

    test "the stored attribution keeps to its share of the session cookie", %{conn: conn} do
      long = String.duplicate("c", 255)

      query =
        URI.encode_query(%{
          "utm_source" => "partner",
          "utm_medium" => "email",
          "utm_campaign" => long,
          "utm_term" => long,
          "utm_content" => long
        })

      conn = get(conn, "/pricing?" <> query)
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      stored = get_session(conn, :analytics_campaign_attribution)
      assert stored["utm_source"] == "partner"
      assert stored["utm_campaign"] == long
      refute Map.has_key?(stored, "utm_term")
      assert Enum.sum(for {key, value} <- stored, do: byte_size(key) + byte_size(value)) <= 512
    end

    test "same-site and invalid referrers never become an acquisition source", %{conn: conn} do
      for referrer <- [
            "http://www.example.com/pricing?internal=secret",
            "https://example.com/",
            "not a URL",
            "javascript:alert(1)"
          ] do
        conn |> put_req_header("referer", referrer) |> get(~p"/pricing")

        assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
        refute Map.has_key?(props, "$initial_referrer")
        refute Map.has_key?(props, "$initial_referring_domain")
      end
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

    test "campaign source and medium are normalized while the X click id stays out of Mixpanel",
         %{conn: conn} do
      conn =
        get(
          conn,
          "/?utm_source=X&utm_medium=Paid_Social&utm_campaign=launch&twclid=x-click-123"
        )

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      refute Map.has_key?(props, "twclid")

      attribution = EmisarWeb.MarketingAttribution.current(conn)
      assert attribution.campaign["utm_source"] == "x"
      assert attribution.x_click_id == "x-click-123"
    end

    test "Global Privacy Control drops X click attribution but keeps first-party campaign data",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("sec-gpc", "1")
        |> get("/?utm_source=X&utm_medium=Paid_Social&twclid=private-click")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      refute Map.has_key?(props, "twclid")

      attribution = EmisarWeb.MarketingAttribution.current(conn)
      assert attribution.x_click_id == nil
      refute inspect(get_session(conn, :analytics_campaign_attribution)) =~ "private-click"
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
    conn =
      conn
      |> put_req_header("referer", "https://directory.example/listing?lead=private")
      |> get("/?utm_source=x&utm_medium=paid_social&utm_campaign=launch")

    assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

    email = "lead-#{System.unique_integer([:positive])}@example.com"
    conn |> recycle() |> post(~p"/subscribe", %{"email" => email, "source" => "footer"})

    assert_receive {:mixpanel_track, [%{"event" => "lead_captured", "properties" => props}]}
    assert props["source"] == "footer"
    assert props["utm_source"] == "x"
    assert props["utm_medium"] == "paid_social"
    assert props["utm_campaign"] == "launch"
    assert props["$initial_referrer"] == "https://directory.example/"
    assert props["$initial_referring_domain"] == "directory.example"
  end

  describe "identity" do
    setup do
      account = Fixtures.Accounts.create_account()

      member =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          email: "id-#{System.unique_integer([:positive])}@example.com",
          display_name: "Jane Op"
        )

      {:ok, member: member, account: account}
    end

    # The code's link from the mailbox, opened in the browser that asked for it.
    defp follow_code_link(conn) do
      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)
      conn |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{secret}")
    end

    defp sign_up_params do
      %{
        "sign_up" => %{
          "email" => "founder-#{System.unique_integer([:positive])}@example.com",
          "full_name" => "Analytics Owner",
          "account_name" => "Analytics Co #{System.unique_integer([:positive])}"
        }
      }
    end

    test "a code sign-in sets the Member's profile and fires signed_in with the Member id", %{
      conn: conn,
      member: member,
      account: account
    } do
      enable_x_conversions()

      conn =
        get(
          conn,
          "/?utm_source=x&utm_medium=paid_social&utm_campaign=launch&twclid=existing-user-click"
        )

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      conn =
        conn
        |> recycle()
        |> post(~p"/app/#{account}/sign_in/email", %{"user" => %{"email" => member.email}})
        |> follow_code_link()

      refute get_session(conn, :analytics_campaign_attribution)

      assert_receive {:mixpanel_engage, [%{"$distinct_id" => id, "$set" => set} = update]}

      assert id == member.id
      assert set["$email"] == member.email
      assert set["$name"] == "Jane Op"
      refute Map.has_key?(update, "$set_once")

      assert_receive {:mixpanel_track, [%{"event" => "signed_in", "properties" => props}]}
      assert props["distinct_id"] == member.id
      assert props["$user_id"] == member.id
      assert props["auth_method"] == "magic_link"
      assert props["mfa"] == false
      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
      refute Map.has_key?(props, "$current_url")
      refute_receive {:x_ads_signup, _conversion}
    end

    test "a completed sign-up carries first-touch attribution", %{conn: conn} do
      enable_x_conversions()
      params = sign_up_params()

      conn =
        conn
        |> put_req_header("referer", "https://partner.example/guide?invite=private")
        |> get("/?utm_source=x&utm_medium=paid_social&utm_campaign=launch&twclid=x-click-123")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      started = conn |> recycle() |> post(~p"/sign_up", params)
      refute_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}

      follow_code_link(started)

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_started", "properties" => started}]}
      assert started["auth_method"] == "magic_link"
      assert started["utm_source"] == "x"
      assert started["utm_medium"] == "paid_social"
      assert started["utm_campaign"] == "launch"
      assert started["$initial_referrer"] == "https://partner.example/"
      assert started["$initial_referring_domain"] == "partner.example"

      assert_receive {:mixpanel_engage, [set_update, %{"$set_once" => set_once}]}
      assert set_update["$set"]["$email"] == params["sign_up"]["email"]
      assert set_once["initial_utm_source"] == "x"
      assert set_once["initial_utm_medium"] == "paid_social"
      assert set_once["initial_utm_campaign"] == "launch"
      assert set_once["$initial_referrer"] == "https://partner.example/"
      assert set_once["$initial_referring_domain"] == "partner.example"

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_completed", "properties" => props}]}

      assert props["utm_source"] == "x"
      assert props["utm_medium"] == "paid_social"
      assert props["utm_campaign"] == "launch"
      assert props["$initial_referrer"] == "https://partner.example/"
      assert props["$initial_referring_domain"] == "partner.example"

      assert_receive {:x_ads_signup, conversion}
      assert conversion.x_click_id == "x-click-123"
      refute inspect(conversion) =~ params["sign_up"]["email"]
    end

    test "GPC on sign-up completion prevents an attributed X conversion", %{conn: conn} do
      enable_x_conversions()

      conn = get(conn, "/?utm_source=x&utm_campaign=launch&twclid=gpc-before-complete")
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"}]}

      started = conn |> recycle() |> post(~p"/sign_up", sign_up_params())
      refute_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}

      follow_code_link_with_gpc(started)

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}
      assert_receive {:mixpanel_engage, _updates}
      assert_receive {:mixpanel_track, [%{"event" => "sign_up_completed"}]}
      refute_receive {:x_ads_signup, _conversion}
    end

    test "a resent code does not duplicate sign_up_started", %{conn: conn} do
      started =
        conn
        |> get("/?utm_source=x&utm_campaign=launch")
        |> recycle()
        |> post(~p"/sign_up", sign_up_params())

      refute_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}
      assert_received {:email, _first_sent}

      resent = started |> recycle() |> post(~p"/sign_in/magic/resend")
      refute_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}

      follow_code_link(resent)

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}
      refute_receive {:mixpanel_track, [%{"event" => "sign_up_started"}]}
    end

    test "sign-out fires signed_out once per Member that ended", %{conn: conn, member: member} do
      other = Fixtures.Memberships.create_membership(email: member.email)
      conn |> log_in_member(member) |> log_in_member(other) |> delete(~p"/sign_out")

      for _member <- 1..2 do
        assert_receive {:mixpanel_track, [%{"event" => "signed_out", "properties" => props}]}
        assert props["distinct_id"] in [member.id, other.id]
      end

      refute_receive {:mixpanel_track, [%{"event" => "signed_out"}]}
    end
  end

  describe "console (LiveView) pageviews" do
    test "a console mount fires page_viewed — authenticated, with the path", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)
      assert is_nil(owner.last_active_at)

      {:ok, _lv, _html} = live(conn, ~p"/app/#{account.slug}")

      assert %DateTime{} = Emisar.Repo.reload!(owner).last_active_at
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["authenticated"] == true
      assert props["distinct_id"] == owner.id
      assert props["$user_id"] == owner.id
      # Path is normalized — the account slug collapses to :account so console
      # pages aggregate (UUID detail segments collapse to :id the same way).
      assert props["path"] == "/app/:account"
      # The client IP is forwarded (test peer, since no x-forwarded-for header).
      assert props["ip"]
      # account_id rides every console event so Group Analytics can roll usage
      # up by account (the group key).
      assert props["account_id"] == account.id
    end

    test "the disconnected render does not touch membership activity", %{conn: conn} do
      {conn, owner, account} = register_and_log_in(conn)

      conn = get(conn, ~p"/app/#{account.slug}")

      assert html_response(conn, 200)
      assert is_nil(Emisar.Repo.reload!(owner).last_active_at)
    end
  end

  defp follow_code_link_with_gpc(started) do
    assert_received {:email, sent}
    [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/([0-9A-Z]{6})", sent.text_body)

    started
    |> recycle()
    |> put_req_header("sec-gpc", "1")
    |> get(~p"/sign_in/magic/#{token_id}/#{secret}")
  end

  defp enable_x_conversions do
    parent = self()
    Emisar.Config.put_override(:emisar, :x_ads_conversions, %{})

    Emisar.Config.put_override(:emisar, :x_ads_conversion_sender, fn _config, event ->
      send(parent, {:x_ads_signup, event})
      :ok
    end)
  end
end

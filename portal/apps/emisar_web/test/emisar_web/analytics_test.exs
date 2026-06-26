defmodule EmisarWeb.AnalyticsTest do
  # async: false — flips the global `:mixpanel_enabled` app env.
  use EmisarWeb.ConnCase, async: false

  setup do
    Application.put_env(:emisar, :mixpanel_enabled, true)
    Application.put_env(:emisar, :analytics_test_pid, self())

    on_exit(fn ->
      Application.put_env(:emisar, :mixpanel_enabled, false)
      Application.delete_env(:emisar, :analytics_test_pid)
    end)

    :ok
  end

  describe "pageview plug" do
    test "a marketing GET fires page_viewed with a cookieless $device: id", %{conn: conn} do
      conn = get(conn, ~p"/pricing")

      # Cookieless: nothing analytics-related is written to the session.
      refute Plug.Conn.get_session(conn, :analytics_device_id)
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["path"] == "/pricing"
      assert props["authenticated"] == false
      # Anonymous distinct_id is the $device:-prefixed daily hash, so Mixpanel
      # treats it as a mergeable device, not a separate identified user.
      assert "$device:" <> _ = props["distinct_id"]
    end

    test "the same visitor gets a stable id across requests — no cookie needed", %{conn: conn} do
      base = put_req_header(conn, "user-agent", "Mozilla/5.0 (X11; Linux) Firefox/121.0")

      get(base, ~p"/pricing")
      assert_receive {:mixpanel_track, [%{"properties" => %{"distinct_id" => first}}]}
      get(base, ~p"/security")
      assert_receive {:mixpanel_track, [%{"properties" => %{"distinct_id" => second}}]}

      # Same IP + UA (same day) → same daily hash → countable as one visitor,
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

    test "tracks regardless of DNT / GPC (cookieless first-party — nothing to opt out of)",
         %{conn: conn} do
      conn |> put_req_header("dnt", "1") |> put_req_header("sec-gpc", "1") |> get(~p"/pricing")
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end

    test "first-touch UTM rides the pageview", %{conn: conn} do
      get(conn, "/?utm_source=hn&utm_campaign=launch")

      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["utm_source"] == "hn"
      assert props["utm_campaign"] == "launch"
    end

    test "the console (/app) is not pageview-tracked", %{conn: conn} do
      # Unauthenticated /app redirects (not a 200 html render), so no page_viewed.
      conn |> get(~p"/app")
      refute_receive {:mixpanel_track, [%{"event" => "page_viewed"} | _]}
    end
  end

  test "footer subscribe fires lead_captured", %{conn: conn} do
    email = "lead-#{System.unique_integer([:positive])}@example.com"
    post(conn, ~p"/subscribe", %{"email" => email, "source" => "footer"})

    assert_receive {:mixpanel_track, [%{"event" => "lead_captured", "properties" => props}]}
    assert props["source"] == "footer"
  end

  describe "identity" do
    setup do
      {:ok, user} =
        Emisar.Users.register_user(%{
          email: "id-#{System.unique_integer([:positive])}@example.com",
          full_name: "Jane Op"
        })

      {:ok, user: Emisar.Fixtures.confirm_user(user)}
    end

    test "a magic-link sign-in sets the profile and fires signed_in with the user id", %{
      conn: conn,
      user: user
    } do
      # Drive the real passwordless flow: request the link, pull token_id + the
      # 6-digit secret from the email, then confirm from the same browser (the
      # nonce cookie rides `recycle`). `log_in_user` fires the analytics event.
      conn = post(conn, ~p"/sign_in/magic/start", %{"user" => %{"email" => user.email}})
      assert_received {:email, sent}
      [_, token_id, secret] = Regex.run(~r"/sign_in/magic/([^/]+)/(\d{6})", sent.text_body)
      conn |> recycle() |> get(~p"/sign_in/magic/#{token_id}/#{secret}")

      assert_receive {:mixpanel_engage, [%{"$distinct_id" => id, "$set" => set}]}
      assert id == user.id
      assert set["$email"] == user.email
      assert set["$name"] == "Jane Op"

      assert_receive {:mixpanel_track, [%{"event" => "signed_in", "properties" => props}]}
      assert props["distinct_id"] == user.id
      assert props["$user_id"] == user.id
      assert props["auth_method"] == "magic_link"
      assert props["mfa"] == false
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

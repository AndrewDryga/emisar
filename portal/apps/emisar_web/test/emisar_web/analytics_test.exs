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
    test "a marketing GET sets the anonymous device id and fires page_viewed", %{conn: conn} do
      conn = get(conn, ~p"/pricing")

      assert Plug.Conn.get_session(conn, :analytics_device_id)
      assert_receive {:mixpanel_track, [%{"event" => "page_viewed", "properties" => props}]}
      assert props["path"] == "/pricing"
      assert props["authenticated"] == false
      assert is_binary(props["distinct_id"])
    end

    test "DNT:1 suppresses tracking and writes no id", %{conn: conn} do
      conn = conn |> put_req_header("dnt", "1") |> get(~p"/pricing")

      refute Plug.Conn.get_session(conn, :analytics_device_id)
      refute_receive {:mixpanel_track, _}
    end

    test "Sec-GPC:1 suppresses tracking", %{conn: conn} do
      conn |> put_req_header("sec-gpc", "1") |> get(~p"/pricing")
      refute_receive {:mixpanel_track, _}
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
          full_name: "Jane Op",
          password: "very-long-password-here"
        })

      {:ok, user: Emisar.Fixtures.confirm_user(user)}
    end

    test "sign-in sets the profile and fires signed_in with the user id", %{
      conn: conn,
      user: user
    } do
      post(conn, ~p"/sign_in",
        user: %{"email" => user.email, "password" => "very-long-password-here"}
      )

      assert_receive {:mixpanel_engage, [%{"$distinct_id" => id, "$set" => set}]}
      assert id == user.id
      assert set["$email"] == user.email
      assert set["$name"] == "Jane Op"

      assert_receive {:mixpanel_track, [%{"event" => "signed_in", "properties" => props}]}
      assert props["distinct_id"] == user.id
      assert props["$user_id"] == user.id
      assert props["auth_method"] == "password"
      assert props["mfa"] == false
    end

    test "a registration completion fires sign_up_completed", %{conn: conn, user: user} do
      post(conn, ~p"/sign_in?_action=registered",
        user: %{"email" => user.email, "password" => "very-long-password-here"}
      )

      assert_receive {:mixpanel_track, [%{"event" => "sign_up_completed", "properties" => props}]}
      assert props["distinct_id"] == user.id
    end

    test "logout fires signed_out", %{conn: conn, user: user} do
      conn |> log_in_user(user) |> delete(~p"/sign_out")

      assert_receive {:mixpanel_track, [%{"event" => "signed_out", "properties" => props}]}
      assert props["distinct_id"] == user.id
    end
  end
end

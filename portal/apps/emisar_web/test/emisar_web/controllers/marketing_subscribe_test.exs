defmodule EmisarWeb.MarketingSubscribeTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Marketing.Signup
  alias Emisar.Repo

  describe "POST /subscribe" do
    test "captures a valid email, flashes success, stores the row", %{conn: conn} do
      conn =
        post(conn, ~p"/subscribe", %{"email" => "buyer@example.com", "source" => "footer"})

      assert redirected_to(conn) == "/#updates"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "subscribed"
      assert %Signup{source: "footer"} = Repo.get_by(Signup, email: "buyer@example.com")
    end

    test "redirects back to the referring page", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://emisar.dev/pricing")
        |> post(~p"/subscribe", %{"email" => "ref@example.com"})

      assert redirected_to(conn) == "/pricing#updates"
    end

    test "never open-redirects off-site — only the referer path is used", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "https://evil.example/owned")
        |> post(~p"/subscribe", %{"email" => "safe@example.com"})

      assert redirected_to(conn) == "/owned#updates"
      refute redirected_to(conn) =~ "evil.example"
    end

    test "rejects a malformed email with an error flash and stores nothing", %{conn: conn} do
      conn = post(conn, ~p"/subscribe", %{"email" => "not-an-email"})

      assert redirected_to(conn) == "/#updates"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "valid email"
      refute Repo.exists?(Signup)
    end

    test "honeypot — a filled company field stores nothing but still flashes success",
         %{conn: conn} do
      conn = post(conn, ~p"/subscribe", %{"email" => "bot@example.com", "company" => "Acme"})

      assert redirected_to(conn) == "/#updates"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "subscribed"
      refute Repo.exists?(Signup)
    end
  end
end

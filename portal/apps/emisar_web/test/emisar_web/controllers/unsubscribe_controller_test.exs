defmodule EmisarWeb.UnsubscribeControllerTest do
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Crypto, Repo}
  alias Emisar.Fixtures

  defp token_for(account), do: Crypto.monthly_report_unsubscribe_token(account.id)

  describe "GET /unsubscribe/monthly-report/:token" do
    test "renders a confirmation page naming the account, without unsubscribing", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      conn = get(conn, ~p"/unsubscribe/monthly-report/#{token_for(account)}")

      assert html_response(conn, 200) =~ account.name
      assert html_response(conn, 200) =~ "Unsubscribe"
      assert html_response(conn, 200) =~ "for every Owner in this workspace, not just you"
      refute html_response(conn, 200) =~ "to this address"
      # A read-only GET (link prefetch) must not opt anyone out.
      refute Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "404s on a forged token", %{conn: conn} do
      conn = get(conn, ~p"/unsubscribe/monthly-report/not-a-real-token")
      assert html_response(conn, 404) =~ "workspace is no longer available"
    end
  end

  describe "POST /unsubscribe/monthly-report/:token" do
    test "opts the account out and confirms", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      conn = post(conn, ~p"/unsubscribe/monthly-report/#{token_for(account)}")

      assert html_response(conn, 200) =~ "Monthly reports are off"
      assert html_response(conn, 200) =~ "are off for every Owner in this workspace"
      assert Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "404s on a forged token", %{conn: conn} do
      conn = post(conn, ~p"/unsubscribe/monthly-report/nope")
      assert html_response(conn, 404) =~ "workspace is no longer available"
    end
  end

  describe "the shared hourly limit" do
    # The POST is also a mail provider's RFC 8058 one-click call, so only the
    # page a person opens gets the readable refusal.
    test "refuses the page readably and keeps the one-click POST's JSON" do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)
      n = System.unique_integer([:positive])
      forwarded = "198.18.#{rem(div(n, 256), 256)}.#{rem(n, 256)}, 8.233.97.247"
      from_ip = fn -> put_req_header(build_conn(), "x-forwarded-for", forwarded) end

      for _attempt <- 1..60 do
        assert get(from_ip.(), ~p"/unsubscribe/monthly-report/nope").status == 404
      end

      page = get(from_ip.(), ~p"/unsubscribe/monthly-report/nope")
      assert html_response(page, 429) =~ "Try again in 1 hour."
      assert get_resp_header(page, "retry-after") == ["3600"]

      one_click = post(from_ip.(), ~p"/unsubscribe/monthly-report/nope")
      assert json_response(one_click, 429)["error"] == "rate_limited"
    end
  end
end

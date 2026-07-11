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
      # A read-only GET (link prefetch) must not opt anyone out.
      refute Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "404s on a forged token", %{conn: conn} do
      conn = get(conn, ~p"/unsubscribe/monthly-report/not-a-real-token")
      assert html_response(conn, 404) =~ "malformed"
    end
  end

  describe "POST /unsubscribe/monthly-report/:token" do
    test "opts the account out and confirms", %{conn: conn} do
      account = Fixtures.Accounts.create_account()

      conn = post(conn, ~p"/unsubscribe/monthly-report/#{token_for(account)}")

      assert html_response(conn, 200) =~ "unsubscribed"
      assert Repo.reload!(account).settings.monthly_report_opt_out
    end

    test "404s on a forged token", %{conn: conn} do
      conn = post(conn, ~p"/unsubscribe/monthly-report/nope")
      assert html_response(conn, 404) =~ "malformed"
    end
  end
end

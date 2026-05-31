defmodule EmisarWeb.RunnerSocketTest do
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Runners

  describe "POST /runner/register (bearer-authed)" do
    setup do
      {:ok, user} =
        Emisar.Accounts.register_user(%{
          email: "owner-#{System.unique_integer([:positive])}@example.com",
          password: "very-long-password-1234"
        })

      {:ok, account} =
        Emisar.Accounts.create_account_with_owner(
          %{name: "OwnerCo", slug: Emisar.Accounts.suggest_unique_slug("OwnerCo"), plan: "team"},
          user
        )

      subject = Emisar.Fixtures.subject_for(user, account, role: :owner)
      {:ok, raw_key, _key} = Runners.create_auth_key(%{description: "test"}, subject)
      %{account: account, user: user, raw_key: raw_key}
    end

    test "exchanges auth key for runner token", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> raw_key)
        |> post(~p"/runner/register", %{
          "hostname" => "ip-10-0-0-1",
          "group" => "default",
          "version" => "0.2.0"
        })

      assert %{"runner_id" => _, "token" => "rnrtok-" <> _, "account_id" => _} =
               json_response(conn, 201)
    end

    test "rejects missing bearer", %{conn: conn} do
      conn = post(conn, ~p"/runner/register", %{})
      assert json_response(conn, 401) == %{"error" => "missing_bearer"}
    end

    test "rejects bogus auth key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer emkey-auth-NOTREAL")
        |> post(~p"/runner/register", %{})

      assert json_response(conn, 401) == %{"error" => "auth_key_invalid"}
    end
  end

  describe "GET /healthz" do
    test "returns ok", %{conn: conn} do
      assert json_response(get(conn, ~p"/healthz"), 200) == %{"status" => "ok"}
    end
  end
end

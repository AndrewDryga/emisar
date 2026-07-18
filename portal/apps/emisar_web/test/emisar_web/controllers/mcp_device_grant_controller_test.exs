defmodule EmisarWeb.MCPDeviceGrantControllerTest do
  @moduledoc """
  The RFC 8628-shaped device-authorization pair the MCP installer drives:
  open a grant, poll it through every state, and receive the per-client
  keys exactly once after portal approval.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.ApiKeys
  alias Emisar.ApiKeys.DeviceGrant
  alias Emisar.{Fixtures, Repo}

  defp approver_subject do
    user = Fixtures.Users.create_user()
    account = Fixtures.Accounts.create_account()

    Fixtures.Memberships.create_membership(
      account_id: account.id,
      user_id: user.id,
      role: "owner"
    )

    Fixtures.Subjects.subject_for(user, account, role: :owner)
  end

  describe "POST /api/mcp/device_authorization" do
    test "opens a pending grant and returns the RFC 8628 envelope", %{conn: conn} do
      conn =
        post(conn, ~p"/api/mcp/device_authorization", %{
          "requested_clients" => ["claude-code", "cursor"]
        })

      body = json_response(conn, 200)
      assert String.starts_with?(body["device_code"], "emdg-")

      assert body["user_code"] =~
               ~r/^[2-9ABCDEFGHJKMNPQRSTVWXYZ]{4}-[2-9ABCDEFGHJKMNPQRSTVWXYZ]{4}$/

      assert body["verification_uri"] == "http://www.example.com/activate"

      assert body["verification_uri_complete"] ==
               "http://www.example.com/activate?code=" <> body["user_code"]

      assert body["expires_in"] == 15 * 60
      assert body["interval"] == 5

      assert [grant] = Repo.all(DeviceGrant)
      assert grant.status == :pending
      assert grant.requested_clients == ["claude-code", "cursor"]
    end

    test "an unknown client or empty list is invalid_request", %{conn: conn} do
      conn = post(conn, ~p"/api/mcp/device_authorization", %{"requested_clients" => ["netscape"]})
      assert %{"error" => "invalid_request"} = json_response(conn, 400)
      assert Repo.all(DeviceGrant) == []
    end

    test "a missing client list is invalid_request", %{conn: conn} do
      conn = post(conn, ~p"/api/mcp/device_authorization", %{})
      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "POST /api/mcp/device_token" do
    test "a pending grant polls as authorization_pending", %{conn: conn} do
      {:ok, device_code, _user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %Emisar.RequestContext{})

      conn = post(conn, ~p"/api/mcp/device_token", %{"device_code" => device_code})
      assert json_response(conn, 400) == %{"error" => "authorization_pending"}
    end

    test "an approved grant delivers the per-client keys exactly once", %{conn: conn} do
      subject = approver_subject()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code", "codex"], %Emisar.RequestContext{})

      {:ok, _approved} = ApiKeys.approve_device_grant(user_code, subject)

      first = post(conn, ~p"/api/mcp/device_token", %{"device_code" => device_code})
      assert %{"client_keys" => client_keys} = json_response(first, 200)
      assert client_keys |> Map.keys() |> Enum.sort() == ["claude-code", "codex"]
      assert String.starts_with?(client_keys["codex"], "emk-")

      # Single-shot delivery: the next poll can never re-issue secrets.
      second = post(conn, ~p"/api/mcp/device_token", %{"device_code" => device_code})
      assert json_response(second, 400) == %{"error" => "invalid_grant"}
    end

    test "a denied grant polls as access_denied", %{conn: conn} do
      subject = approver_subject()

      {:ok, device_code, user_code, _grant} =
        ApiKeys.open_device_grant(["claude-code"], %Emisar.RequestContext{})

      {:ok, _denied} = ApiKeys.deny_device_grant(user_code, subject)

      conn = post(conn, ~p"/api/mcp/device_token", %{"device_code" => device_code})
      assert json_response(conn, 400) == %{"error" => "access_denied"}
    end

    test "an expired grant polls as expired_token", %{conn: conn} do
      {:ok, device_code, _user_code, grant} =
        ApiKeys.open_device_grant(["claude-code"], %Emisar.RequestContext{})

      Fixtures.ApiKeys.backdate_device_grant_expiry(grant)

      conn = post(conn, ~p"/api/mcp/device_token", %{"device_code" => device_code})
      assert json_response(conn, 400) == %{"error" => "expired_token"}
    end

    test "an unknown or missing device_code is rejected", %{conn: conn} do
      unknown = post(conn, ~p"/api/mcp/device_token", %{"device_code" => "emdg-unknown"})
      assert json_response(unknown, 400) == %{"error" => "invalid_grant"}

      missing = post(conn, ~p"/api/mcp/device_token", %{})
      assert %{"error" => "invalid_request"} = json_response(missing, 400)
    end
  end
end

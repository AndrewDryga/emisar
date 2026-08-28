defmodule EmisarWeb.SCIM.ResponseTest do
  @moduledoc """
  The shared SCIM response contract, tested where both resource controllers meet.

  `revoked/1` exists because Users and Groups met one cause — a connection
  disabled, deleted, or downgraded off its plan between authentication and the
  mutation's provider-row fence — and gave two verdicts. Users answered 401;
  Groups had no clause and fell through to its `400 invalidValue` catch-all. An
  IdP reads 401 as "fix the credential" and pauses, and 4xx invalidValue as
  "this object's payload is bad", which makes it mark the object errored and
  retry forever with the same body.

  That branch is only reachable in a revoke race — `authenticate_scim_token/1`
  applies the same billing and liveness checks the fence does, so no HTTP test
  can reach it deterministically. Pinning the shared renderer here is what keeps
  the two routes from drifting again.
  """
  use EmisarWeb.ConnCase, async: true
  alias EmisarWeb.SCIM.Response

  describe "revoked/1" do
    test "answers 401 with a bearer challenge and the SCIM error media type", %{conn: conn} do
      conn = Response.revoked(conn)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")

      body = Jason.decode!(conn.resp_body)
      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "401"
    end
  end
end

defmodule EmisarWeb.SCIMGroupsControllerTest do
  @moduledoc """
  The inbound SCIM 2.0 `/Groups` surface — directory-group → role sync an IdP
  pushes. Covers: provision a group + a mapped member's role becoming the mapped
  role, cross-account token isolation (account A can't push into B), PATCH
  add/remove recomputing the role, the 401 SCIM-error gate, DELETE → 204, and an
  unsupported PATCH op surfacing a SCIM error (never a silent no-op).

  The token's provider-scope IS the authorization, so the tests mint a REAL
  per-provider bearer via `SSO.enable_scim/2` and drive everything over HTTP.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Repo, SSO}
  alias Emisar.SSO.IdentityProvider

  @scim_content_type "application/scim+json"

  # Enterprise account + a SCIM-enabled provider. Returns the provider, its raw
  # bearer (shown once), the owner subject, and the account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_user, account, subject} = owner_subject_fixture(%{plan: "enterprise"})
    provider = provider_fixture(account, provider_attrs)
    {:ok, provider, raw_token} = SSO.enable_scim(provider, subject)
    %{provider: provider, token: raw_token, subject: subject, account: account}
  end

  defp provider_fixture(account, attrs) do
    attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true,
          default_role: :viewer
        },
        Map.new(attrs)
      )

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
  end

  # Provision a directory user through the domain and return its identity.
  defp provision(provider, external_id) do
    {:ok, %{identity: identity}} =
      SSO.scim_provision_user(provider, %{external_id: external_id, full_name: "Dir User"})

    identity
  end

  defp role_of(account_id, user_id), do: fetch_membership(account_id, user_id).role

  # A SCIM Group payload as Okta/Entra send it.
  defp group_payload(external_id, member_external_ids, opts \\ []) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "externalId" => external_id,
      "displayName" => opts[:display] || external_id,
      "members" => Enum.map(member_external_ids, &%{"value" => &1})
    }
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # Authenticated, SCIM-content-typed request dispatched on the HTTP verb.
  defp scim_send(conn, token, :post, path, body), do: scim_conn(conn, token) |> post(path, body)
  defp scim_send(conn, token, :put, path, body), do: scim_conn(conn, token) |> put(path, body)
  defp scim_send(conn, token, :patch, path, body), do: scim_conn(conn, token) |> patch(path, body)

  defp scim_conn(conn, token),
    do: conn |> auth(token) |> put_req_header("content-type", @scim_content_type)

  # -- Auth gate -------------------------------------------------------

  describe "bearer auth" do
    test "a missing bearer → 401 SCIM error", %{conn: conn} do
      body =
        conn
        |> post(~p"/scim/v2/Groups", group_payload("grp", []))
        |> json_response(401)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "401"
    end

    test "an invalid bearer → 401 + WWW-Authenticate", %{conn: conn} do
      conn = conn |> auth("ems-bogus") |> get(~p"/scim/v2/Groups")

      assert json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  # -- POST /Groups ----------------------------------------------------

  describe "POST /Groups" do
    test "provisions a group and a mapped member's role becomes the mapped role", %{conn: conn} do
      %{token: token, provider: provider, subject: subject, account: account} = scim_provider()

      # A mapping (grp-ops → :operator) + a provisioned member at the default :viewer.
      {:ok, _mapping} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", external_group_display: "Operators", role: :operator},
          subject
        )

      identity = provision(provider, "okta|u1")
      assert role_of(account.id, identity.user_id) == :viewer

      body =
        conn
        |> scim_send(
          token,
          :post,
          ~p"/scim/v2/Groups",
          group_payload("grp-ops", ["okta|u1"], display: "Operators")
        )
        |> json_response(201)

      # The SCIM Group resource.
      assert body["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:Group"]
      assert body["id"] == "grp-ops"
      assert body["displayName"] == "Operators"
      assert body["members"] == [%{"value" => "okta|u1"}]
      assert body["meta"]["resourceType"] == "Group"

      # The member's role was recomputed to the mapped role.
      assert role_of(account.id, identity.user_id) == :operator
    end

    test "an unmapped member in the group is tracked but its role is unchanged", %{conn: conn} do
      %{token: token, provider: provider, account: account} = scim_provider()
      identity = provision(provider, "okta|nomap")

      # No mapping for grp-x → the member stays at the default role.
      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", group_payload("grp-x", ["okta|nomap"]))
        |> json_response(201)

      assert body["id"] == "grp-x"
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "a payload with no externalId/displayName → 400 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", %{"members" => []})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
    end
  end

  # -- Cross-account isolation -----------------------------------------

  describe "cross-account isolation" do
    test "an account-A token cannot push groups into account B", %{conn: conn} do
      %{token: token_a, provider: provider_a, subject: subject_a, account: account_a} =
        scim_provider()

      %{provider: provider_b, subject: subject_b, account: account_b} = scim_provider()

      # Same external group id + role mapped in BOTH accounts; a member with the
      # SAME external id provisioned in each.
      {:ok, _} =
        SSO.create_group_mapping(provider_a, %{external_group_id: "grp", role: :admin}, subject_a)

      {:ok, _} =
        SSO.create_group_mapping(provider_b, %{external_group_id: "grp", role: :admin}, subject_b)

      id_a = provision(provider_a, "okta|shared")
      id_b = provision(provider_b, "okta|shared")

      # Push the group with account A's token only.
      assert conn
             |> scim_send(
               token_a,
               :post,
               ~p"/scim/v2/Groups",
               group_payload("grp", ["okta|shared"])
             )
             |> json_response(201)

      # A's member was promoted; B's identically-named member is untouched.
      assert role_of(account_a.id, id_a.user_id) == :admin
      assert role_of(account_b.id, id_b.user_id) == :viewer
    end
  end

  # -- PATCH /Groups/:id -----------------------------------------------

  describe "PATCH /Groups/:id" do
    test "add then remove members recomputes the affected roles", %{conn: conn} do
      %{token: token, provider: provider, subject: subject, account: account} = scim_provider()

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|patch")
      assert role_of(account.id, identity.user_id) == :viewer

      # ADD the member to the mapped group → role recomputes to :admin.
      add_body = %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "okta|patch"}]}
        ]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-adm", add_body)
             |> json_response(200)

      assert role_of(account.id, identity.user_id) == :admin

      # REMOVE via the Okta filtered-path shape. With no mapped group left the
      # role resets to the provider default_role (:viewer) — least-privilege (#3).
      remove_body = %{
        "Operations" => [%{"op" => "remove", "path" => "members[value eq \"okta|patch\"]"}]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-adm", remove_body)
             |> json_response(200)

      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "an unsupported PATCH op → SCIM error, not a silent no-op", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp", %{
          "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "Renamed"}]
        })
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidPath"
    end
  end

  # -- DELETE / PUT / GET ----------------------------------------------

  describe "DELETE / PUT / GET" do
    test "DELETE empties the group and recomputes (204)", %{conn: conn} do
      %{token: token, provider: provider, subject: subject, account: account} = scim_provider()

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|del")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|del"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      conn = conn |> auth(token) |> delete(~p"/scim/v2/Groups/grp-adm")
      assert response(conn, 204)

      # The group is emptied; with no mapped group the role resets to the
      # provider default_role (:viewer) — least-privilege on removal (#3).
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "PUT replaces the group's membership (200)", %{conn: conn} do
      %{token: token, provider: provider, subject: subject, account: account} = scim_provider()

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      identity = provision(provider, "okta|put")

      body =
        conn
        |> scim_send(
          token,
          :put,
          ~p"/scim/v2/Groups/grp-ops",
          group_payload("grp-ops", ["okta|put"])
        )
        |> json_response(200)

      assert body["id"] == "grp-ops"
      assert role_of(account.id, identity.user_id) == :operator
    end

    test "GET /Groups returns an empty SCIM ListResponse (no group read)", %{conn: conn} do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/Groups") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      assert body["totalResults"] == 0
    end

    test "GET /Groups/:id → 404 SCIM error (no group read)", %{conn: conn} do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/Groups/grp-x") |> json_response(404)
      assert body["status"] == "404"
    end
  end
end

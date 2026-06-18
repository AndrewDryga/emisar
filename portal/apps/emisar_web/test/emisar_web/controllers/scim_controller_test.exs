defmodule EmisarWeb.SCIMControllerTest do
  @moduledoc """
  The inbound SCIM 2.0 surface (`/scim/v2`) — the directory-sync lifecycle an
  IdP pushes. Covers the §4 web cases: cross-account token isolation, the 401
  SCIM-error gate, provision + idempotent reconcile, the `active:false` and
  DELETE deprovision (suspend, not delete), the last-active-owner lockout,
  read + filter, and a discovery endpoint behind auth.

  The token's provider-scope IS the authorization, so the tests mint a REAL
  per-provider bearer via `SSO.enable_scim/2` and drive everything over HTTP.
  """
  use EmisarWeb.ConnCase, async: true

  import Emisar.Fixtures

  alias Emisar.{Accounts, ApiKeys, Repo, SSO, Users}
  alias Emisar.SSO.IdentityProvider

  @scim_content_type "application/scim+json"

  # Enterprise account + a provider with directory sync enabled. Returns the
  # provider, its raw bearer (shown once), the owner subject, and the account.
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

  # Insert `count` newer directory identities (all bound to one user — a user
  # may hold many) so an earlier-provisioned target is pushed past the
  # `GET /Users` page limit, exercising the query-level filter.
  defp page_off_target(provider, user_id, count) do
    newer = DateTime.utc_now() |> DateTime.add(60, :second)

    rows =
      for n <- 1..count do
        %{
          id: Repo.generate_id(),
          account_id: provider.account_id,
          provider_id: provider.id,
          user_id: user_id,
          provider_identifier: "filler|#{n}",
          scim_external_id: "filler|#{n}",
          claims: %{},
          created_by: :provider,
          provisioned_via: :scim,
          scim_active: true,
          inserted_at: newer,
          updated_at: newer
        }
      end

    Repo.insert_all(SSO.UserIdentity, rows)
  end

  # A SCIM User payload as Okta/Entra send it.
  defp user_payload(external_id, opts) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "externalId" => external_id,
      "userName" => opts[:user_name] || "#{external_id}@acme.test",
      "active" => Keyword.get(opts, :active, true),
      "name" => %{"formatted" => opts[:full_name] || "Dir User"},
      "emails" => [%{"primary" => true, "value" => opts[:email] || "#{external_id}@acme.test"}]
    }
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp scim_post(conn, token, path, body) do
    conn
    |> auth(token)
    |> put_req_header("content-type", @scim_content_type)
    |> post(path, body)
  end

  # -- Auth gate -------------------------------------------------------

  describe "bearer auth" do
    test "a missing bearer → 401 SCIM error", %{conn: conn} do
      body = conn |> get(~p"/scim/v2/Users/anything") |> json_response(401)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "401"
      assert is_binary(body["detail"])
    end

    test "a malformed Authorization header → 401", %{conn: conn} do
      assert conn
             |> put_req_header("authorization", "Basic abc123")
             |> get(~p"/scim/v2/Users/anything")
             |> json_response(401)
    end

    test "an invalid bearer → 401 + WWW-Authenticate", %{conn: conn} do
      conn = conn |> auth("ems-totally-bogus-token") |> get(~p"/scim/v2/Users/x")

      assert json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "a lowercase `bearer` scheme is accepted (RFC 7235 — the scheme is case-insensitive)",
         %{conn: conn} do
      %{token: token} = scim_provider()

      conn =
        conn |> put_req_header("authorization", "bearer " <> token) |> get(~p"/scim/v2/Users")

      assert json_response(conn, 200)
    end

    test "surrounding + collapsed whitespace on the bearer is tolerated (paste artifacts)",
         %{conn: conn} do
      %{token: token} = scim_provider()

      conn =
        conn
        |> put_req_header("authorization", "  Bearer   " <> token <> "  ")
        |> get(~p"/scim/v2/Users")

      assert json_response(conn, 200)
    end

    test "a bare `ems-` token with no scheme is accepted (Okta Header Auth sends it raw)",
         %{conn: conn} do
      %{token: token} = scim_provider()

      conn = conn |> put_req_header("authorization", token) |> get(~p"/scim/v2/Users")
      assert json_response(conn, 200)
    end

    test "a schemeless `ems-` value with the wrong secret → 401 (the hash still gates)",
         %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "ems-totally-bogus-token")
        |> get(~p"/scim/v2/Users")

      assert json_response(conn, 401)
    end

    test "a schemeless value without our `ems-` namespace → 401", %{conn: conn} do
      conn =
        conn |> put_req_header("authorization", "not-a-real-token") |> get(~p"/scim/v2/Users")

      assert json_response(conn, 401)
    end

    test "a disabled-SCIM provider's old bearer → 401", %{conn: conn} do
      %{provider: provider, token: token, subject: subject} = scim_provider()
      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert conn |> auth(token) |> get(~p"/scim/v2/Users/x") |> json_response(401)
    end
  end

  # -- Cross-account isolation -----------------------------------------

  describe "cross-account isolation" do
    test "an account-A token cannot touch account B — provision lands only in A", %{conn: conn} do
      %{token: token_a, account: account_a} = scim_provider()
      %{account: account_b} = scim_provider()

      body =
        conn
        |> scim_post(
          token_a,
          ~p"/scim/v2/Users",
          user_payload("okta|scoped", email: "scoped@acme.test")
        )
        |> json_response(201)

      {:ok, user} = Users.fetch_user_by_email("scoped@acme.test")

      assert Accounts.peek_sync_membership(account_a.id, user.id)
      refute Accounts.peek_sync_membership(account_b.id, user.id)
      assert body["externalId"] == "okta|scoped"
    end
  end

  # -- POST /Users -----------------------------------------------------

  describe "POST /Users" do
    test "provisions a user (201) with the SCIM User resource", %{conn: conn} do
      %{token: token, account: account} = scim_provider()

      body =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|new", email: "new@acme.test"))
        |> json_response(201)

      assert body["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:User"]
      assert body["externalId"] == "okta|new"
      assert body["userName"] == "new@acme.test"
      assert body["active"] == true
      assert body["meta"]["resourceType"] == "User"
      # The resource id is the externalId (the domain's stable key).
      assert body["id"] == "okta|new"

      {:ok, user} = Users.fetch_user_by_email("new@acme.test")
      assert Accounts.peek_sync_membership(account.id, user.id)
    end

    test "a repeated POST for the same externalId reconciles — no duplicate", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      first =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|dup", email: "dup@acme.test"))
        |> json_response(201)

      second =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|dup", email: "dup@acme.test"))
        |> json_response(201)

      assert first["id"] == second["id"]

      {:ok, identities, _meta} = SSO.scim_list_users(provider)
      assert Enum.count(identities, &(&1.scim_external_id == "okta|dup")) == 1
    end

    test "a payload with no externalId or userName → 400 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", %{"active" => true})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
    end
  end

  # -- Deprovision -----------------------------------------------------

  describe "PATCH active:false / DELETE deprovision" do
    test "PATCH active:false suspends the membership (not delete)", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|patch",
          email: "patch@acme.test",
          full_name: "P"
        })

      patch_body = %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
      }

      body =
        conn
        |> auth(token)
        |> put_req_header("content-type", @scim_content_type)
        |> patch(~p"/scim/v2/Users/okta|patch", patch_body)
        |> json_response(200)

      assert body["active"] == false

      membership = Accounts.peek_sync_membership(account.id, user.id)
      assert membership.disabled_at
      # The user survives — deprovision suspends, never deletes.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PATCH active:false with a pathless value map (Entra shape) works", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|entra", email: "e@acme.test"})

      patch_body = %{"Operations" => [%{"op" => "Replace", "value" => %{"active" => false}}]}

      assert conn
             |> auth(token)
             |> put_req_header("content-type", @scim_content_type)
             |> patch(~p"/scim/v2/Users/okta|entra", patch_body)
             |> json_response(200)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "an unsupported PATCH op → SCIM error, not a silent no-op", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|np", email: "np@acme.test"})

      patch_body = %{
        "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "Renamed"}]
      }

      body =
        conn
        |> auth(token)
        |> put_req_header("content-type", @scim_content_type)
        |> patch(~p"/scim/v2/Users/okta|np", patch_body)
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
    end

    test "PATCH active:true reinstates a suspended membership", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|re", email: "re@acme.test"})

      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|re")
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      patch_body = %{"Operations" => [%{"op" => "replace", "path" => "active", "value" => true}]}

      body =
        conn
        |> auth(token)
        |> put_req_header("content-type", @scim_content_type)
        |> patch(~p"/scim/v2/Users/okta|re", patch_body)
        |> json_response(200)

      assert body["active"] == true
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "DELETE deprovisions the same way (204, soft suspend)", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|del", email: "del@acme.test"})

      conn = conn |> auth(token) |> delete(~p"/scim/v2/Users/okta|del")
      assert response(conn, 204)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "deprovisioning the last active owner → SCIM error, not 204", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :viewer})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|owner", email: "o@acme.test"})

      # Make the provisioned user the account's single active owner.
      membership = fetch_membership(account.id, user.id)
      force_membership_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      body =
        conn
        |> auth(token)
        |> delete(~p"/scim/v2/Users/okta|owner")
        |> json_response(409)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "409"
      # Still active — the lockout guard held.
      refute fetch_membership(account.id, user.id).disabled_at
    end

    test "DELETE of an unknown externalId → 404 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> auth(token)
        |> delete(~p"/scim/v2/Users/okta|ghost")
        |> json_response(404)

      assert body["status"] == "404"
    end
  end

  # -- Read + list -----------------------------------------------------

  describe "GET /Users" do
    test "GET /Users/:id returns the resource; unknown id → 404", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|read", email: "read@acme.test"})

      body = conn |> auth(token) |> get(~p"/scim/v2/Users/okta|read") |> json_response(200)
      assert body["externalId"] == "okta|read"
      # On a read the domain returns a bare identity (no joined user), which
      # stores no email — so userName renders as the externalId, the stable
      # handle we always have. (POST, which carries the user, renders the email.)
      assert body["userName"] == "okta|read"

      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|missing") |> json_response(404)
    end

    test "GET /Users with a userName filter returns just the match", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      # IdPs commonly set userName = the email and use it as the externalId
      # too; the filter matches the identity's stable handle.
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "a@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "b@acme.test"})

      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=userName eq \"a@acme.test\"")
        |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      assert body["totalResults"] == 1
      assert [%{"externalId" => "a@acme.test"}] = body["Resources"]
    end

    test "GET /Users with an externalId filter returns just the match", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "okta|x", email: "x@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "okta|y", email: "y@acme.test"})

      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=externalId eq \"okta|y\"")
        |> json_response(200)

      assert body["totalResults"] == 1
      assert [%{"externalId" => "okta|y"}] = body["Resources"]
    end

    test "GET /Users with an unsupported filter is declined with 400 invalidFilter",
         %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "okta|1", email: "1@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "okta|2", email: "2@acme.test"})

      # A present filter we can't honor must NOT dump the whole directory — an
      # existence probe would misread "got results" as "the user exists". Decline
      # it (the `eq` probes IdPs actually send still work). Two users exist, so
      # this proves we decline rather than just happening to return empty.
      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=userName sw \"foo\"")
        |> json_response(400)

      assert body["scimType"] == "invalidFilter"
    end

    test "GET /Users filter finds a user beyond the first page (the match runs in the query)",
         %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      # Provision the target first (so it's the oldest identity), then push it
      # past the page limit with 100 newer ones. A page-then-filter-in-memory
      # implementation would miss it; the query-level filter finds it wherever
      # it sits — without this, an IdP's existence probe re-creates a duplicate.
      {:ok, %{identity: target}} =
        SSO.scim_provision_user(provider, %{external_id: "target@acme.test"})

      page_off_target(provider, target.user_id, 100)

      for filter <- ["externalId eq \"target@acme.test\"", "userName eq \"target@acme.test\""] do
        body =
          conn
          |> auth(token)
          |> get(~p"/scim/v2/Users?filter=#{filter}")
          |> json_response(200)

        assert body["totalResults"] == 1, "off-page user not found via `#{filter}`"
        assert [%{"externalId" => "target@acme.test"}] = body["Resources"]
      end
    end

    test "GET /Users is scoped to the provider — never another provider's identities", %{
      conn: conn
    } do
      %{token: token_a, provider: provider_a} = scim_provider()
      %{provider: provider_b} = scim_provider()

      {:ok, _} =
        SSO.scim_provision_user(provider_a, %{external_id: "okta|in-a", email: "a@a.test"})

      {:ok, _} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|in-b", email: "b@b.test"})

      body = conn |> auth(token_a) |> get(~p"/scim/v2/Users") |> json_response(200)

      external_ids = Enum.map(body["Resources"], & &1["externalId"])
      assert "okta|in-a" in external_ids
      refute "okta|in-b" in external_ids
    end
  end

  # -- Discovery -------------------------------------------------------

  describe "discovery" do
    test "GET /ServiceProviderConfig is 200 behind auth and declares our support", %{conn: conn} do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(200)

      assert body["patch"]["supported"] == true
      assert body["filter"]["supported"] == true
      assert body["bulk"]["supported"] == false
      assert [%{"type" => "oauthbearertoken"}] = body["authenticationSchemes"]
    end

    test "discovery endpoints require the bearer too", %{conn: conn} do
      assert conn |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(401)
      assert conn |> get(~p"/scim/v2/ResourceTypes") |> json_response(401)
      assert conn |> get(~p"/scim/v2/Schemas") |> json_response(401)
    end
  end

  # Promote-then-isolate the last owner: demote every OTHER owner so the kept
  # user is the account's single active owner (mirrors the domain test helper).
  defp demote_other_owners(account_id, except: keep_user_id) do
    Accounts.Membership.Query.not_deleted()
    |> Accounts.Membership.Query.by_account_id(account_id)
    |> Accounts.Membership.Query.by_role(:owner)
    |> Repo.all()
    |> Enum.reject(&(&1.user_id == keep_user_id))
    |> Enum.each(&force_membership_role(&1, "admin"))
  end

  # Suppress unused-alias warnings — referenced via `~p` / fixtures.
  _ = {ApiKeys}
end

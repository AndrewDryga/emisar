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
  alias EmisarWeb.SCIM.Resource

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

  defp scim_put(conn, token, path, body) do
    conn
    |> auth(token)
    |> put_req_header("content-type", @scim_content_type)
    |> put(path, body)
  end

  defp scim_patch(conn, token, path, body) do
    conn
    |> auth(token)
    |> put_req_header("content-type", @scim_content_type)
    |> patch(path, body)
  end

  # A PATCH PatchOp body flipping `active` (Okta path shape).
  defp active_patch(active) do
    %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => [%{"op" => "replace", "path" => "active", "value" => active}]
    }
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

    test "a payload the user changeset rejects → 400 invalidValue", %{conn: conn} do
      %{token: token} = scim_provider()

      # externalId is present (passes the blank gate), but the email carries a
      # space — the provision changeset's email validate_format rejects it. A
      # NON-unique changeset error flows back to render_error(%Changeset{}) →
      # 400 invalidValue, never a 500.
      body =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", %{
          "externalId" => "okta|badmail",
          "emails" => [%{"primary" => true, "value" => "no good@acme.test"}]
        })
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidValue"
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

    test "a case-insensitive op keyword (`Replace`) still flips active", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|ci", email: "ci@acme.test"})

      patch_body = %{
        "Operations" => [%{"op" => "Replace", "path" => "active", "value" => false}]
      }

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|ci", patch_body)
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a PATCH whose ops never touch `active` → 400 invalidPath", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|noact", email: "noact@acme.test"})

      # A real PatchOp shape, but no operation targets `active` — an honest
      # invalidPath, not a silent no-op (the active op simply isn't present).
      patch_body = %{
        "Operations" => [%{"op" => "add", "path" => "nickName", "value" => "nick"}]
      }

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|noact", patch_body)
        |> json_response(400)

      assert body["scimType"] == "invalidPath"
    end

    test "a non-list `Operations` → 400 invalidValue", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|nl", email: "nl@acme.test"})

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|nl", %{"Operations" => "replace active"})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH with no `Operations` key → 400 invalidSyntax", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|ns", email: "ns@acme.test"})

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|ns", %{"active" => false})
        |> json_response(400)

      assert body["scimType"] == "invalidSyntax"
    end

    test "a PATCH active:false on an unknown externalId → 404", %{conn: conn} do
      %{token: token} = scim_provider(%{default_role: :admin})

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|nobody", active_patch(false))
        |> json_response(404)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "404"
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

    test "a re-DELETE of an already-suspended user is idempotent (204 again)", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|redel", email: "redel@acme.test"})

      assert conn |> auth(token) |> delete(~p"/scim/v2/Users/okta|redel") |> response(204)
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # The second DELETE re-suspends the already-disabled membership — a no-op at
      # the membership layer, still 204 (the identity row lives on, so it resolves).
      assert conn |> auth(token) |> delete(~p"/scim/v2/Users/okta|redel") |> response(204)
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a PATCH active op whose value can't be parsed → 400 invalidValue", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|bad", email: "bad@acme.test"})

      # A real active op, but the value "maybe" is neither a boolean nor the
      # Entra string "True"/"False" — parse_active → nil → :error → invalidValue.
      patch_body = %{
        "Operations" => [%{"op" => "replace", "path" => "active", "value" => "maybe"}]
      }

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|bad", patch_body)
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH active:true on an already-active member is idempotent (200, still active)",
         %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|aa", email: "aa@acme.test"})

      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|aa", active_patch(true))
        |> json_response(200)

      assert body["active"] == true
      # Reinstating an already-active membership is a no-op — still active.
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a PATCH active:true on an unknown externalId → 404", %{conn: conn} do
      %{token: token} = scim_provider(%{default_role: :admin})

      body =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/okta|nobody-react", active_patch(true))
        |> json_response(404)

      assert body["status"] == "404"
    end

    test "a soft-deleted identity is excluded — GET/PATCH/DELETE → 404", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|gone", email: "gone@acme.test"})

      # Tombstone the identity row directly — every scoped read starts at
      # not_deleted(), so the directory connection can no longer see it.
      {:ok, _} =
        identity |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|gone") |> json_response(404)

      assert conn
             |> scim_patch(token, ~p"/scim/v2/Users/okta|gone", active_patch(false))
             |> json_response(404)

      assert conn |> auth(token) |> delete(~p"/scim/v2/Users/okta|gone") |> json_response(404)

      # And it never appears in the directory list.
      body = conn |> auth(token) |> get(~p"/scim/v2/Users") |> json_response(200)
      refute "okta|gone" in Enum.map(body["Resources"], & &1["externalId"])
    end
  end

  # -- PUT /Users (full replace, active flip) --------------------------

  describe "PUT /Users/:id" do
    test "PUT active:false suspends the membership", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-off-bool",
          email: "pob@acme.test"
        })

      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # A plain JSON boolean `active:false` (the canonical PUT replace) parses via
      # parse_active → false → apply_active deactivate → 200 User resource; the
      # membership is suspended (R8: PUT active:false maps to scim_deactivate_user).
      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-off-bool", %{"active" => false})
        |> json_response(200)

      assert body["active"] == false
      assert body["externalId"] == "okta|put-off-bool"
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # Suspend, never delete — the user row survives.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PUT active:true reactivates a suspended membership", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-on", email: "puton@acme.test"})

      {:ok, _} = SSO.scim_deactivate_user(provider, "okta|put-on")
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-on", %{"active" => true})
        |> json_response(200)

      assert body["active"] == true
      assert body["externalId"] == "okta|put-on"
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "PUT with the Entra string `\"False\"` suspends the membership", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-off",
          email: "putoff@acme.test"
        })

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-off", %{"active" => "False"})
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # Suspend, never delete — the user row survives.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PUT acts on `active` only — other body attributes are ignored", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-ignore",
          email: "ignore@acme.test",
          full_name: "Original Name"
        })

      # The PUT flips active:false and ALSO carries a displayName + emails — only
      # `active` is acted on; the other attributes are immutable post-provision.
      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-ignore", %{
          "active" => false,
          "displayName" => "Renamed By IdP",
          "emails" => [%{"primary" => true, "value" => "renamed@acme.test"}]
        })
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # The user's name + email were NOT rewritten by the PUT.
      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.full_name == "Original Name"
      assert reloaded.email == "ignore@acme.test"
    end

    test "PUT with no `active` → 400 invalidValue", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-na", email: "na@acme.test"})

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-na", %{"displayName" => "Renamed"})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
      assert body["scimType"] == "invalidValue"
    end

    test "PUT with an unparseable `active` → 400 invalidValue", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider(%{default_role: :admin})

      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-bad", email: "bad@acme.test"})

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-bad", %{"active" => "maybe"})
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "PUT on an unknown externalId → 404 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-ghost", %{"active" => false})
        |> json_response(404)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "404"
    end

    test "PUT active:false on the sole active owner → 409 mutability, untouched", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :viewer})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-owner", email: "po@acme.test"})

      # Make the provisioned user the account's single active owner.
      membership = fetch_membership(account.id, user.id)
      force_membership_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      body =
        conn
        |> scim_put(token, ~p"/scim/v2/Users/okta|put-owner", %{"active" => false})
        |> json_response(409)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "409"
      assert body["scimType"] == "mutability"
      # Still active — the last-owner guard held; scim_active untouched.
      refute fetch_membership(account.id, user.id).disabled_at
    end
  end

  # -- Cross-provider no-leak isolation --------------------------------

  describe "cross-provider isolation (a foreign externalId is 404, never a leak)" do
    test "DELETE of an account-B externalId → 404; B untouched", %{conn: conn} do
      %{token: token_a} = scim_provider()
      %{provider: provider_b, account: account_b} = scim_provider(%{default_role: :admin})

      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|in-b", email: "inb@acme.test"})

      body =
        conn
        |> auth(token_a)
        |> delete(~p"/scim/v2/Users/okta|in-b")
        |> json_response(404)

      assert body["status"] == "404"
      # B's membership is untouched — A's token never reached it.
      refute Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PUT active:true on an account-B externalId → 404; B's suspension stands", %{conn: conn} do
      %{token: token_a} = scim_provider()
      %{provider: provider_b, account: account_b} = scim_provider(%{default_role: :admin})

      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|susp-b", email: "sb@acme.test"})

      {:ok, _} = SSO.scim_deactivate_user(provider_b, "okta|susp-b")

      assert conn
             |> scim_put(token_a, ~p"/scim/v2/Users/okta|susp-b", %{"active" => true})
             |> json_response(404)

      # B stays suspended — A's reactivate never reached B's membership.
      assert Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PATCH active:true on an account-B externalId → 404; B's suspension stands", %{
      conn: conn
    } do
      %{token: token_a} = scim_provider()
      %{provider: provider_b, account: account_b} = scim_provider(%{default_role: :admin})

      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|patch-b", email: "pb@acme.test"})

      {:ok, _} = SSO.scim_deactivate_user(provider_b, "okta|patch-b")

      assert conn
             |> scim_patch(token_a, ~p"/scim/v2/Users/okta|patch-b", active_patch(true))
             |> json_response(404)

      assert Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PATCH active:false on an account-B externalId → 404; B's member stays active",
         %{conn: conn} do
      %{token: token_a} = scim_provider()
      %{provider: provider_b, account: account_b} = scim_provider(%{default_role: :admin})

      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|live-b", email: "lb@acme.test"})

      assert conn
             |> scim_patch(token_a, ~p"/scim/v2/Users/okta|live-b", active_patch(false))
             |> json_response(404)

      # B's member is still active — A's deactivate never reached B.
      refute Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end
  end

  # -- Full lifecycle round-trip ---------------------------------------

  describe "provisioning lifecycle" do
    test "POST → PATCH active:false → PATCH active:true → DELETE, asserting state at each step",
         %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      ext = "okta|lifecycle"

      # 1. Provision → active member, user + identity created.
      provisioned =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload(ext, email: "life@acme.test"))
        |> json_response(201)

      assert provisioned["active"] == true
      assert provisioned["id"] == ext

      {:ok, user} = Users.fetch_user_by_email("life@acme.test")
      membership = Accounts.peek_sync_membership(account.id, user.id)
      assert membership
      refute membership.disabled_at

      # 2. Deactivate → membership suspended, identity flagged inactive.
      deactivated =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/#{ext}", active_patch(false))
        |> json_response(200)

      assert deactivated["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # 3. Reactivate → membership reinstated.
      reactivated =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/#{ext}", active_patch(true))
        |> json_response(200)

      assert reactivated["active"] == true
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # 4. DELETE → SUSPEND, never destroy: 204, membership disabled, user kept.
      assert conn |> auth(token) |> delete(~p"/scim/v2/Users/#{ext}") |> response(204)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # The user row + identity persist — DELETE deactivates, it does not hard-delete.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
      assert {:ok, _identity} = SSO.scim_fetch_user(provider, ext)
    end

    test "`scim_active` drift is self-corrected on the next reconcile (re-POST)", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :admin})

      {:ok, %{user: user, identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|drift", email: "drift@acme.test"})

      # Force the identity flag out of sync with the (still-active) membership —
      # scim_active says inactive, but the member is not suspended.
      {:ok, _} =
        identity |> Ecto.Changeset.change(scim_active: false) |> Repo.update()

      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # The next reconcile (a re-POST) realigns scim_active with the live
      # membership state — load_provisioned flips it back to true.
      body =
        conn
        |> scim_post(
          token,
          ~p"/scim/v2/Users",
          user_payload("okta|drift", email: "drift@acme.test")
        )
        |> json_response(201)

      assert body["active"] == true
      {:ok, reloaded} = SSO.scim_fetch_user(provider, "okta|drift")
      assert reloaded.scim_active
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

    test "GET /Users/:id matches scim_external_id only — not the provider_identifier fallback", %{
      conn: conn
    } do
      # (asserts the REAL behavior, which differs from the
      # test-plan's optimistic claim). The list filter `externalId eq` coalesces
      # scim_external_id → provider_identifier (UserIdentity.Query.by_external_id),
      # but the single-fetch `GET /Users/:id` (scim_fetch_user →
      # by_provider_and_scim_external_id) matches scim_external_id ONLY. For a
      # SCIM-provisioned identity the two ids coincide (decision 4), so this is
      # not reachable in practice — but it documents that the fetch path does NOT
      # fall back to provider_identifier. No product bug: SCIM only ever fetches
      # identities it provisioned, which always carry scim_external_id.
      %{token: token, provider: provider} = scim_provider()

      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|coalesce", email: "c@acme.test"})

      # Drop scim_external_id, leaving only provider_identifier set.
      {:ok, _} =
        identity |> Ecto.Changeset.change(scim_external_id: nil) |> Repo.update()

      # The single-fetch does NOT coalesce → 404 on the provider_identifier.
      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|coalesce") |> json_response(404)

      # …but the LIST filter, which DOES coalesce, still finds it by externalId.
      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=externalId eq \"okta|coalesce\"")
        |> json_response(200)

      assert body["totalResults"] == 1
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

    test "an UNQUOTED filter value is accepted (regex allows quoted or unquoted)", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "a@acme.test"})
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "b@acme.test"})

      # No surrounding quotes around the value — the parse_filter regex matches
      # the unquoted form too, so the same match is returned as the quoted probe.
      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=userName eq a@acme.test")
        |> json_response(200)

      assert body["totalResults"] == 1
      assert [%{"externalId" => "a@acme.test"}] = body["Resources"]
    end

    test "an UNFILTERED list past the page cap returns a partial (≤100) list", %{conn: conn} do
      %{token: token, provider: provider} = scim_provider()

      # One real provisioned identity, then push the directory well past the 100
      # page cap. An unfiltered list is capped at the page limit (push IdPs
      # filter, they don't enumerate), so the response is a partial list — never
      # the whole directory, and never a crash.
      {:ok, %{identity: anchor}} =
        SSO.scim_provision_user(provider, %{external_id: "anchor@acme.test"})

      page_off_target(provider, anchor.user_id, 120)

      body = conn |> auth(token) |> get(~p"/scim/v2/Users") |> json_response(200)

      resources = body["Resources"]
      assert length(resources) == 100
      assert body["totalResults"] == 100
    end
  end

  # -- Discovery -------------------------------------------------------

  describe "discovery" do
    test "GET /ServiceProviderConfig is 200 behind auth and declares our support", %{conn: conn} do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(200)

      assert body["patch"]["supported"] == true
      assert body["filter"]["supported"] == true
      # The declared filter cap mirrors the real list page limit (scim_list_users
      # `page: [limit: 100]`), so the IdP never expects more than we return — no
      # drift between the advertised cap and the actual enforced one (SCIM-008).
      assert body["filter"]["maxResults"] == 100
      assert body["bulk"]["supported"] == false
      assert body["sort"]["supported"] == false
      assert body["etag"]["supported"] == false
      assert body["changePassword"]["supported"] == false
      assert [%{"type" => "oauthbearertoken", "primary" => true}] = body["authenticationSchemes"]
      # documentationUri + meta.location are built from the public base URL.
      base = Emisar.PublicUrl.base()
      assert body["documentationUri"] == "#{base}/docs/teams-and-access"
      assert body["meta"]["location"] == "#{base}/scim/v2/ServiceProviderConfig"
    end

    test "the config is identical regardless of which provider's bearer fetches it", %{conn: conn} do
      %{token: token_a} = scim_provider()
      %{token: token_b} = scim_provider()

      body_a =
        conn |> auth(token_a) |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(200)

      body_b =
        conn |> auth(token_b) |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(200)

      assert body_a == body_b
    end

    test "GET /ResourceTypes lists exactly the User descriptor (Group is push-only)", %{
      conn: conn
    } do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/ResourceTypes") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      # Exactly one resource-type — the User descriptor. No Group descriptor:
      # group sync is push-only, so we never advertise a Group resource.
      assert [user_type] = body["Resources"]
      assert user_type["id"] == "User"
      assert user_type["name"] == "User"
      assert user_type["endpoint"] == "/Users"
      assert user_type["schema"] == "urn:ietf:params:scim:schemas:core:2.0:User"
      assert user_type["meta"]["location"] == "/scim/v2/ResourceTypes/User"
      refute Enum.any?(body["Resources"], &(&1["id"] == "Group"))
      # ListResponse counts equal the number of resources (1).
      assert body["totalResults"] == 1
      assert body["itemsPerPage"] == 1
    end

    test "GET /Schemas declares the User schema's three attributes", %{conn: conn} do
      %{token: token} = scim_provider()

      body = conn |> auth(token) |> get(~p"/scim/v2/Schemas") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      assert [user_schema] = body["Resources"]
      assert user_schema["id"] == "urn:ietf:params:scim:schemas:core:2.0:User"

      attrs = Map.new(user_schema["attributes"], &{&1["name"], &1})

      # userName: required, server-unique, readWrite.
      assert attrs["userName"]["type"] == "string"
      assert attrs["userName"]["required"] == true
      assert attrs["userName"]["uniqueness"] == "server"
      assert attrs["userName"]["mutability"] == "readWrite"

      # active: optional boolean. externalId: optional, caseExact. Deliberate
      # subset — only userName is required even though the parser reads email/name.
      assert attrs["active"]["type"] == "boolean"
      assert attrs["active"]["required"] == false
      assert attrs["externalId"]["required"] == false
      assert attrs["externalId"]["caseExact"] == true
      refute Map.has_key?(attrs, "emails")
      refute Map.has_key?(attrs, "name")
    end

    test "discovery endpoints require the bearer too", %{conn: conn} do
      assert conn |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(401)
      assert conn |> get(~p"/scim/v2/ResourceTypes") |> json_response(401)
      assert conn |> get(~p"/scim/v2/Schemas") |> json_response(401)
    end
  end

  # -- Response envelope -----------------------------------------------

  describe "response envelope" do
    test "the outbound content-type is `application/json`, not `application/scim+json`", %{
      conn: conn
    } do
      %{token: token} = scim_provider()

      conn = conn |> auth(token) |> get(~p"/scim/v2/ServiceProviderConfig")
      assert json_response(conn, 200)

      # We respond via Phoenix `json/2`, so the content-type is plain
      # `application/json`. The `+json` SCIM suffix is accepted INBOUND only
      # (router :scim pipeline); strict clients expecting `application/scim+json`
      # back would be surprised — documented here so the choice is deliberate.
      assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")
    end
  end

  # -- Inbound payload parsing (Resource.parse_user) -------------------

  describe "Resource.parse_user/1" do
    test "externalId is taken directly when present" do
      assert %{external_id: "okta|direct"} = Resource.parse_user(%{"externalId" => "okta|direct"})
    end

    test "externalId falls back to userName when absent" do
      assert %{external_id: "user@acme.test"} =
               Resource.parse_user(%{"userName" => "user@acme.test"})
    end

    test "the primary email is chosen over the others" do
      params = %{
        "externalId" => "okta|p",
        "emails" => [
          %{"value" => "secondary@acme.test"},
          %{"primary" => true, "value" => "primary@acme.test"}
        ]
      }

      assert %{email: "primary@acme.test"} = Resource.parse_user(params)
    end

    test "with no primary flag, the first non-empty email value wins" do
      params = %{
        "externalId" => "okta|f",
        "emails" => [%{"value" => ""}, %{"value" => "first@acme.test"}]
      }

      assert %{email: "first@acme.test"} = Resource.parse_user(params)
    end

    test "an email-like userName is used as the email when no emails are sent" do
      assert %{email: "handle@acme.test"} =
               Resource.parse_user(%{"externalId" => "okta|h", "userName" => "handle@acme.test"})

      # A non-email userName does NOT become an email.
      assert %{email: nil} =
               Resource.parse_user(%{"externalId" => "okta|h2", "userName" => "plainhandle"})
    end

    test "full_name resolves formatted → assembled → displayName, in that order" do
      formatted = %{
        "externalId" => "okta|n1",
        "name" => %{"formatted" => "Ada Lovelace", "givenName" => "Ada", "familyName" => "L"},
        "displayName" => "Ada D"
      }

      assert %{full_name: "Ada Lovelace"} = Resource.parse_user(formatted)

      assembled = %{
        "externalId" => "okta|n2",
        "name" => %{"givenName" => "Grace", "familyName" => "Hopper"},
        "displayName" => "Grace D"
      }

      assert %{full_name: "Grace Hopper"} = Resource.parse_user(assembled)

      display_only = %{"externalId" => "okta|n3", "displayName" => "Just Display"}
      assert %{full_name: "Just Display"} = Resource.parse_user(display_only)
    end

    test ~s|Entra's string `"True"`/`"False"` active is parsed case-insensitively|, %{
      conn: _conn
    } do
      assert %{active: true} =
               Resource.parse_user(%{"externalId" => "okta|a1", "active" => "True"})

      assert %{active: false} =
               Resource.parse_user(%{"externalId" => "okta|a2", "active" => "False"})

      # A JSON boolean still works, and an absent active defaults to true.
      assert %{active: false} =
               Resource.parse_user(%{"externalId" => "okta|a3", "active" => false})

      assert %{active: true} = Resource.parse_user(%{"externalId" => "okta|a4"})
    end

    test "an unparseable present active → nil (no active change)" do
      assert %{active: nil} =
               Resource.parse_user(%{"externalId" => "okta|a5", "active" => "maybe"})
    end

    test "non-string fields are dropped without crashing" do
      params = %{"externalId" => "okta|drop", "userName" => 123, "emails" => "not-a-list"}

      assert %{external_id: "okta|drop", email: nil, full_name: nil} = Resource.parse_user(params)
    end

    test "with no name or email, full_name and email are nil (still provisionable)" do
      # Only an externalId — no emails, no name, no displayName, no userName. The
      # user is still identifiable by externalId; email/full_name are just nil.
      assert %{external_id: "okta|bare", email: nil, full_name: nil, active: true} =
               Resource.parse_user(%{"externalId" => "okta|bare"})
    end

    test "arbitrary input keys never grow the atom table (no String.to_atom)" do
      # The parser reads only fixed string-literal keys (IL-14), so feeding it a
      # payload full of never-before-seen string keys must not mint a single atom.
      payload =
        Map.new(1..50, fn n ->
          {"never_seen_key_#{System.unique_integer([:positive])}_#{n}", "v#{n}"}
        end)
        |> Map.put("externalId", "okta|atoms")

      before = :erlang.system_info(:atom_count)
      assert %{external_id: "okta|atoms"} = Resource.parse_user(payload)
      assert :erlang.system_info(:atom_count) == before
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

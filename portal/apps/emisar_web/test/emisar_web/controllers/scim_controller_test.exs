defmodule EmisarWeb.SCIMControllerTest do
  @moduledoc """
  The inbound SCIM 2.0 surface (`/scim/v2`) — the directory-sync lifecycle an
  IdP pushes. Covers the §4 web cases: cross-account token isolation, the 401
  SCIM-error gate, provision + idempotent reconcile, the `active:false` and
  DELETE retirement, the last-active-owner lockout,
  read + filter, and a discovery endpoint behind auth.

  The token's provider-scope IS the authorization, so the tests mint a REAL
  per-provider bearer via `SSO.enable_scim/2` and drive everything over HTTP.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.{Accounts, ApiKeys, Repo, SSO, Users}
  alias Emisar.SSO.{IdentityProvider, SCIMUserUpdate}
  alias EmisarWeb.SCIM.Resource
  alias EmisarWeb.SCIM.UserController

  @scim_content_type "application/scim+json"

  # Enterprise account + a provider with directory sync enabled. Returns the
  # provider, its raw bearer (shown once), the owner subject, and the account.
  defp scim_provider(provider_attrs \\ %{}) do
    {_user, account, subject} = Fixtures.Subjects.owner_subject(%{plan: "enterprise"})
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

  # Insert `count` newer directory identities — one per person, which is the
  # only shape the directory can produce — so an earlier-provisioned target is
  # pushed past the `GET /Users` page limit, exercising the query-level filter.
  defp page_off_target(provider, count) do
    newer = DateTime.utc_now() |> DateTime.add(60, :second)

    rows =
      for n <- 1..count do
        user = Fixtures.Users.create_user()

        %{
          id: Repo.generate_id(),
          account_id: provider.account_id,
          provider_id: provider.id,
          user_id: user.id,
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

  defp scim_get(conn, token, path) do
    conn
    |> auth(token)
    |> get(path)
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

  defp user_resource_id(provider, external_id) do
    SSO.UserIdentity.Query.not_deleted()
    |> SSO.UserIdentity.Query.by_provider_and_scim_external_id(provider.id, external_id)
    |> Repo.fetch!(SSO.UserIdentity.Query)
    |> Map.fetch!(:id)
  end

  defp user_path(token, external_id) do
    {:ok, provider} = SSO.authenticate_scim_token(token)
    "/scim/v2/Users/#{user_resource_id(provider, external_id)}"
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
    setup do
      scim_provider()
    end

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
         %{conn: conn, token: token} do
      conn =
        conn |> put_req_header("authorization", "bearer " <> token) |> get(~p"/scim/v2/Users")

      assert json_response(conn, 200)
    end

    test "surrounding + collapsed whitespace on the bearer is tolerated (paste artifacts)",
         %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "  Bearer   " <> token <> "  ")
        |> get(~p"/scim/v2/Users")

      assert json_response(conn, 200)
    end

    test "a bare `ems-` token with no scheme is accepted (Okta Header Auth sends it raw)",
         %{conn: conn, token: token} do
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

    test "a disabled-SCIM provider's old bearer → 401", %{
      conn: conn,
      provider: provider,
      token: token,
      subject: subject
    } do
      {:ok, _provider} = SSO.disable_scim(provider, subject)

      assert conn |> auth(token) |> get(~p"/scim/v2/Users/x") |> json_response(401)
    end

    test "a provider revoked after bearer resolution still returns the SCIM 401 challenge", %{
      conn: conn,
      provider: stale_provider,
      subject: subject
    } do
      {:ok, _disabled} = SSO.disable_scim(stale_provider, subject)

      conn =
        conn
        |> assign(:scim_provider, stale_provider)
        |> UserController.create(user_payload("okta|revoked-in-flight", []))

      assert json_response(conn, 401)["status"] == "401"
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
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
    setup do
      scim_provider()
    end

    test "provisions a user (201) with the SCIM User resource", %{
      conn: conn,
      token: token,
      account: account
    } do
      conn =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|new", email: "new@acme.test"))

      body = json_response(conn, 201)
      location = Emisar.PublicUrl.url("/scim/v2/Users/#{body["id"]}")

      assert body["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:User"]
      assert body["externalId"] == "okta|new"
      assert body["userName"] == "new@acme.test"
      assert body["active"] == true
      assert body["meta"]["resourceType"] == "User"
      assert body["meta"]["location"] == location
      assert get_resp_header(conn, "location") == [location]
      assert Repo.valid_uuid?(body["id"])
      refute body["id"] == body["externalId"]

      {:ok, user} = Users.fetch_user_by_email("new@acme.test")
      assert Accounts.peek_sync_membership(account.id, user.id)
    end

    test "a POST with active:false provisions the user already suspended (deactivated in the IdP)",
         %{
           conn: conn,
           token: token,
           account: account
         } do
      body =
        conn
        |> scim_post(
          token,
          ~p"/scim/v2/Users",
          user_payload("okta|disabled", email: "disabled@acme.test", active: false)
        )
        |> json_response(201)

      assert body["active"] == false

      {:ok, user} = Users.fetch_user_by_email("disabled@acme.test")
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a repeated POST for the same externalId reconciles — no duplicate", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      first =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|dup", email: "dup@acme.test"))
        |> json_response(201)

      second =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload("okta|dup", email: "dup@acme.test"))
        |> json_response(201)

      assert first["id"] == second["id"]

      {:ok, scim_users, _meta} = SSO.scim_list_users(provider)
      assert Enum.count(scim_users, &(&1.external_id == "okta|dup")) == 1
    end

    test "a payload with no externalId or userName → 400 SCIM error", %{conn: conn, token: token} do
      body =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", %{"active" => true})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
    end

    test "a POST with an unparseable active value is rejected before provisioning", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      body =
        conn
        |> scim_post(
          token,
          ~p"/scim/v2/Users",
          user_payload("okta|invalid-active", email: "invalid-active@acme.test", active: "maybe")
        )
        |> json_response(400)

      assert body["scimType"] == "invalidValue"

      assert SSO.scim_list_users(provider,
               scim_filter: {:external_id, "okta|invalid-active"}
             ) === {:ok, [], 0}
    end

    test "a payload the user changeset rejects → 400 invalidValue", %{conn: conn, token: token} do
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
    setup do
      scim_provider(%{default_role: :admin})
    end

    test "PATCH active:false suspends the membership (not delete)", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
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
        |> patch(user_path(token, "okta|patch"), patch_body)
        |> json_response(200)

      assert body["active"] == false

      membership = Accounts.peek_sync_membership(account.id, user.id)
      assert membership.disabled_at
      # The user survives — deprovision suspends, never deletes.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PATCH active:false with a pathless value map (Entra shape) works", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|entra", email: "e@acme.test"})

      patch_body = %{"Operations" => [%{"op" => "Replace", "value" => %{"active" => false}}]}

      assert conn
             |> auth(token)
             |> put_req_header("content-type", @scim_content_type)
             |> patch(user_path(token, "okta|entra"), patch_body)
             |> json_response(200)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "an unsupported PATCH op → SCIM error, not a silent no-op", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|np", email: "np@acme.test"})

      patch_body = %{
        "Operations" => [%{"op" => "replace", "path" => "title", "value" => "Chief Renamer"}]
      }

      body =
        conn
        |> auth(token)
        |> put_req_header("content-type", @scim_content_type)
        |> patch(user_path(token, "okta|np"), patch_body)
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
    end

    test "a case-insensitive op keyword (`Replace`) still flips active", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|ci", email: "ci@acme.test"})

      patch_body = %{
        "Operations" => [%{"op" => "Replace", "path" => "active", "value" => false}]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|ci"), patch_body)
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "the LAST `active` operation decides, not the first", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|last", email: "last@acme.test"})

      # RFC 7644 applies operations in order — an IdP that reinstates and then
      # offboards in one request means the offboard. Taking the first match let
      # a trailing `active: false` be dropped, leaving the member signed in.
      patch_body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "active", "value" => true},
          %{"op" => "replace", "path" => "active", "value" => false}
        ]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|last"), patch_body)
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "reactivating a manually suspended member reports them still inactive", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account,
      subject: subject
    } do
      # A directory `active: true` deliberately does NOT lift a manual break-glass
      # hold — an operator placed it, an operator lifts it. What was wrong is what
      # we then TOLD the IdP: the identity's flag said active, so the response said
      # active, for someone who cannot sign in. The IdP stops flagging them and
      # nobody finds out.
      {:ok, %{user: user, membership: membership}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|held", email: "held@acme.test"})

      {:ok, _suspended} = Accounts.suspend_membership(membership, subject)

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|held"), %{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => true}]
        })
        |> json_response(200)

      # The hold stands...
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # ...and the IdP is told so, rather than being told the reactivation worked.
      assert body["active"] == false

      # A READ has to say the same thing. Deriving `active` only where a mutation
      # happened to carry a membership meant a GET immediately afterwards answered
      # `true` again — the same lie, one request later.
      read =
        conn
        |> scim_get(token, user_path(token, "okta|held"))
        |> json_response(200)

      assert read["active"] == false
    end

    test "a member removed locally reads inactive and deprovisions cleanly", %{
      conn: conn,
      token: token,
      account: account,
      provider: provider
    } do
      # Removing someone from the account soft-deletes the membership and leaves
      # the identity. The directory was then told two different things: a read said
      # active, a deprovision said no such user. So it either retried forever or
      # concluded they were gone and re-created them — undoing the removal.
      {:ok, %{user: user, membership: membership}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|removed",
          email: "removed@acme.test"
        })

      Fixtures.Memberships.mark_membership_as_deleted(membership)
      refute Accounts.peek_sync_membership(account.id, user.id)

      read =
        conn
        |> scim_get(token, user_path(token, "okta|removed"))
        |> json_response(200)

      assert read["active"] == false

      # ...and the deprovision the directory sends next succeeds, with nothing left
      # to do, rather than 404ing.
      body =
        conn
        |> scim_patch(token, user_path(token, "okta|removed"), active_patch(false))
        |> json_response(200)

      assert body["active"] == false
    end

    test "a PATCH whose ops never touch `active` → 400 invalidPath", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|noact", email: "noact@acme.test"})

      # A real PatchOp shape, but no operation targets `active` — an honest
      # invalidPath, not a silent no-op (the active op simply isn't present).
      patch_body = %{
        "Operations" => [%{"op" => "add", "path" => "nickName", "value" => "nick"}]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|noact"), patch_body)
        |> json_response(400)

      assert body["scimType"] == "invalidPath"
    end

    test "a displayName-only PATCH renames the synced user", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|rename-only",
          email: "rename-only@acme.test",
          full_name: "Old Name"
        })

      patch_body = %{
        "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "New Name"}]
      }

      conn
      |> scim_patch(token, user_path(token, "okta|rename-only"), patch_body)
      |> json_response(200)

      assert Repo.reload!(user).full_name == "New Name"
    end

    test "a pathless Entra-style PATCH value map renames too", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|entra-rename",
          email: "entra-rename@acme.test",
          full_name: "Old Name"
        })

      patch_body = %{
        "Operations" => [%{"op" => "Replace", "value" => %{"displayName" => "Entra Name"}}]
      }

      conn
      |> scim_patch(token, user_path(token, "okta|entra-rename"), patch_body)
      |> json_response(200)

      assert Repo.reload!(user).full_name == "Entra Name"
    end

    test "one PatchOp carrying displayName AND active applies both", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|both-ops",
          email: "both-ops@acme.test",
          full_name: "Old Name"
        })

      patch_body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "displayName", "value" => "Renamed"},
          %{"op" => "replace", "path" => "active", "value" => false}
        ]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|both-ops"), patch_body)
        |> json_response(200)

      assert body["active"] == false
      assert Repo.reload!(user).full_name == "Renamed"
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a PatchOp whose deactivation is refused commits nothing — not even the rename", %{
      conn: conn
    } do
      # The rename and the lifecycle change are one transaction: the 409 the
      # last-active-owner guard answers means the WHOLE operation was rejected,
      # so the directory must not find half of it (the rename) applied.
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :viewer})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|atomic",
          email: "atomic@acme.test",
          full_name: "Old Name"
        })

      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      patch_body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "displayName", "value" => "Half Landed"},
          %{"op" => "replace", "path" => "active", "value" => false}
        ]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|atomic"), patch_body)
        |> json_response(409)

      assert body["status"] == "409"
      assert Repo.reload!(user).full_name == "Old Name"

      unchanged = Fixtures.Memberships.fetch_membership(account.id, user.id)
      refute unchanged.disabled_at
      refute unchanged.directory_display_name
    end

    test "a fresh displayName beats a stale name.formatted the IdP echoed back", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      # We serve `name.formatted`, so Okta sends it straight back on the next
      # write — alongside the NEW displayName. Preferring the formatted value
      # meant the rename was accepted, reported successful, and kept the old name.
      {:ok, _} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|echo",
          email: "echo@acme.test",
          full_name: "Old Name"
        })

      body = %{
        "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "externalId" => "okta|echo",
        "userName" => "echo@acme.test",
        "active" => true,
        "displayName" => "New Name",
        "name" => %{"formatted" => "Old Name", "givenName" => "New"}
      }

      resp = conn |> scim_put(token, user_path(token, "okta|echo"), body) |> json_response(200)
      assert resp["displayName"] == "New Name"
    end

    test "Entra's name-component rename is applied, not refused", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      # Entra renames by sending the components and NO displayName. Recognizing
      # only displayName answered 400 to both operations, so an Entra rename
      # retried and failed forever.
      {:ok, _} =
        SSO.scim_provision_user(provider, %{
          external_id: "entra|name",
          email: "name@acme.test",
          full_name: "Old Name"
        })

      patch = %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations" => [
          %{"op" => "Add", "path" => "name.givenName", "value" => "Renamed"},
          %{"op" => "Add", "path" => "name.familyName", "value" => "Entra R3"}
        ]
      }

      body =
        conn |> scim_patch(token, user_path(token, "entra|name"), patch) |> json_response(200)

      assert body["displayName"] == "Renamed Entra R3"
    end

    test "a component-only rename keeps the half it does not mention", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{
          external_id: "entra|half",
          email: "half@acme.test",
          full_name: "Ada Lovelace"
        })

      patch = %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
        "Operations" => [%{"op" => "replace", "path" => "name.givenName", "value" => "Augusta"}]
      }

      body =
        conn |> scim_patch(token, user_path(token, "entra|half"), patch) |> json_response(200)

      assert body["displayName"] == "Augusta Lovelace"
    end

    test "a PATCH with more operations than the cap → 400 tooMany", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|many", email: "many@acme.test"})

      operations =
        for _ <- 1..101, do: %{"op" => "replace", "path" => "active", "value" => false}

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|many"), %{"Operations" => operations})
        |> json_response(400)

      assert body["scimType"] == "tooMany"
    end

    test "a non-list `Operations` → 400 invalidValue", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|nl", email: "nl@acme.test"})

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|nl"), %{"Operations" => "replace active"})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH with no `Operations` key → 400 invalidSyntax", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|ns", email: "ns@acme.test"})

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|ns"), %{"active" => false})
        |> json_response(400)

      assert body["scimType"] == "invalidSyntax"
    end

    test "a PATCH active:false on an unknown server id → 404", %{conn: conn, token: token} do
      body =
        conn
        |> scim_patch(token, "/scim/v2/Users/#{Ecto.UUID.generate()}", active_patch(false))
        |> json_response(404)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "404"
    end

    test "PATCH active:true reinstates a suspended membership", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|re", email: "re@acme.test"})

      id = user_resource_id(provider, "okta|re")
      {:ok, _} = SSO.scim_update_user(provider, id, %SCIMUserUpdate{active: false})
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      patch_body = %{"Operations" => [%{"op" => "replace", "path" => "active", "value" => true}]}

      body =
        conn
        |> auth(token)
        |> put_req_header("content-type", @scim_content_type)
        |> patch(user_path(token, "okta|re"), patch_body)
        |> json_response(200)

      assert body["active"] == true
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "DELETE suspends the member and retires every wire operation on the resource", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user, identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|del", email: "del@acme.test"})

      path = "/scim/v2/Users/#{identity.id}"
      conn = conn |> auth(token) |> delete(path)
      assert response(conn, 204)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)

      assert conn |> recycle() |> auth(token) |> get(path) |> json_response(404)

      assert conn
             |> recycle()
             |> scim_patch(token, path, active_patch(true))
             |> json_response(404)

      assert conn
             |> recycle()
             |> scim_put(token, path, %{"active" => true})
             |> json_response(404)

      assert conn |> recycle() |> auth(token) |> delete(path) |> json_response(404)

      listed = conn |> recycle() |> scim_get(token, ~p"/scim/v2/Users") |> json_response(200)
      refute identity.id in Enum.map(listed["Resources"], & &1["id"])
    end

    test "deprovisioning the last active owner → SCIM error, not 204", %{conn: conn} do
      %{token: token, provider: provider, account: account} =
        scim_provider(%{default_role: :viewer})

      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|owner", email: "o@acme.test"})

      # Make the provisioned user the account's single active owner.
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      body =
        conn
        |> auth(token)
        |> delete(user_path(token, "okta|owner"))
        |> json_response(409)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "409"
      # Still active — the lockout guard held.
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end

    test "DELETE of an unknown server id → 404 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> auth(token)
        |> delete("/scim/v2/Users/#{Ecto.UUID.generate()}")
        |> json_response(404)

      assert body["status"] == "404"
    end

    test "a re-DELETE of an already-retired user is 404", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user, identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|redel", email: "redel@acme.test"})

      path = "/scim/v2/Users/#{identity.id}"
      deleted = conn |> auth(token) |> delete(path)
      assert response(deleted, 204)
      assert get_resp_header(deleted, "content-type") == ["application/scim+json; charset=utf-8"]
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      assert conn |> recycle() |> auth(token) |> delete(path) |> json_response(404)
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "POST after DELETE revives the same resource and person", %{
      conn: conn,
      token: token,
      account: account
    } do
      payload = user_payload("okta|recreate", email: "recreate@acme.test")
      created = conn |> scim_post(token, ~p"/scim/v2/Users", payload) |> json_response(201)
      {:ok, user} = Users.fetch_user_by_email("recreate@acme.test")

      assert conn
             |> recycle()
             |> auth(token)
             |> delete("/scim/v2/Users/#{created["id"]}")
             |> response(204)

      recreated =
        conn
        |> recycle()
        |> scim_post(token, ~p"/scim/v2/Users", payload)
        |> json_response(201)

      assert recreated["id"] == created["id"]
      assert recreated["active"]
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      identities =
        SSO.UserIdentity.Query.all()
        |> SSO.UserIdentity.Query.by_user_id(user.id)
        |> Repo.all()

      assert [identity] = identities
      assert identity.id == created["id"]
    end

    test "a PATCH active op whose value can't be parsed → 400 invalidValue", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|bad", email: "bad@acme.test"})

      # A real active op, but the value "maybe" is neither a boolean nor the
      # Entra string "True"/"False" — parse_active → nil → :error → invalidValue.
      patch_body = %{
        "Operations" => [%{"op" => "replace", "path" => "active", "value" => "maybe"}]
      }

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|bad"), patch_body)
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH active:true on an already-active member is idempotent (200, still active)",
         %{conn: conn, token: token, provider: provider, account: account} do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|aa", email: "aa@acme.test"})

      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      body =
        conn
        |> scim_patch(token, user_path(token, "okta|aa"), active_patch(true))
        |> json_response(200)

      assert body["active"] == true
      # Reinstating an already-active membership is a no-op — still active.
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "a PATCH active:true on an unknown server id → 404", %{conn: conn, token: token} do
      body =
        conn
        |> scim_patch(token, "/scim/v2/Users/#{Ecto.UUID.generate()}", active_patch(true))
        |> json_response(404)

      assert body["status"] == "404"
    end

    test "a soft-deleted identity is excluded — GET/PATCH/DELETE → 404", %{
      conn: conn,
      token: token,
      provider: provider
    } do
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
    setup do
      scim_provider(%{default_role: :admin})
    end

    test "PUT active:false suspends the membership", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-off-bool",
          email: "pob@acme.test"
        })

      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # A plain JSON boolean `active:false` (the canonical PUT replace) parses via
      # parse_active → false → apply_active deactivate → 200 User resource; the
      # membership is suspended (R8: PUT active:false maps to scim_update_user (active: false)).
      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-off-bool"), %{"active" => false})
        |> json_response(200)

      assert body["active"] == false
      assert body["externalId"] == "okta|put-off-bool"
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # Suspend, never delete — the user row survives.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PUT active:true reactivates a suspended membership", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-on", email: "puton@acme.test"})

      id = user_resource_id(provider, "okta|put-on")
      {:ok, _} = SSO.scim_update_user(provider, id, %SCIMUserUpdate{active: false})
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-on"), %{"active" => true})
        |> json_response(200)

      assert body["active"] == true
      assert body["externalId"] == "okta|put-on"
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at
    end

    test "PUT with a changed displayName renames the synced user", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-rename",
          email: "put-rename@acme.test",
          full_name: "Old Name"
        })

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-rename"), %{
          "active" => true,
          "displayName" => "New Name"
        })
        |> json_response(200)

      assert body["active"] == true
      assert Repo.reload!(user).full_name == "New Name"
    end

    test "PUT with the Entra string `\"False\"` suspends the membership", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-off",
          email: "putoff@acme.test"
        })

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-off"), %{"active" => "False"})
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # Suspend, never delete — the user row survives.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
    end

    test "PUT applies displayName + active — email stays immutable", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      {:ok, %{user: user}} =
        SSO.scim_provision_user(provider, %{
          external_id: "okta|put-ignore",
          email: "ignore@acme.test",
          full_name: "Original Name"
        })

      # The PUT flips active:false and carries a displayName + emails: the
      # IdP-owned name and lifecycle apply; the sign-in email never does (an
      # email rewrite via sync would be an account-takeover surface).
      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-ignore"), %{
          "active" => false,
          "displayName" => "Renamed By IdP",
          "emails" => [%{"primary" => true, "value" => "renamed@acme.test"}]
        })
        |> json_response(200)

      assert body["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      {:ok, reloaded} = Users.fetch_user_by_id(user.id)
      assert reloaded.full_name == "Renamed By IdP"
      assert reloaded.email == "ignore@acme.test"
    end

    test "PUT with no `active` → 400 invalidValue", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-na", email: "na@acme.test"})

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-na"), %{"displayName" => "Renamed"})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
      assert body["scimType"] == "invalidValue"
    end

    test "PUT with an unparseable `active` → 400 invalidValue", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} =
        SSO.scim_provision_user(provider, %{external_id: "okta|put-bad", email: "bad@acme.test"})

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-bad"), %{"active" => "maybe"})
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "PUT on an unknown server id → 404 SCIM error", %{conn: conn} do
      %{token: token} = scim_provider()

      body =
        conn
        |> scim_put(token, "/scim/v2/Users/#{Ecto.UUID.generate()}", %{"active" => false})
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
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_role(membership, "owner")
      demote_other_owners(account.id, except: user.id)

      body =
        conn
        |> scim_put(token, user_path(token, "okta|put-owner"), %{"active" => false})
        |> json_response(409)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "409"
      assert body["scimType"] == "mutability"
      # Still active — the last-owner guard held; scim_active untouched.
      refute Fixtures.Memberships.fetch_membership(account.id, user.id).disabled_at
    end
  end

  # -- Cross-provider no-leak isolation --------------------------------

  describe "cross-provider isolation (a foreign server id is 404, never a leak)" do
    setup do
      %{token: token_a} = scim_provider()
      %{provider: provider_b, account: account_b} = scim_provider(%{default_role: :admin})
      %{token_a: token_a, provider_b: provider_b, account_b: account_b}
    end

    test "DELETE of an account-B server id → 404; B untouched", %{
      conn: conn,
      token_a: token_a,
      provider_b: provider_b,
      account_b: account_b
    } do
      {:ok, %{identity: identity_b, user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|in-b", email: "inb@acme.test"})

      body =
        conn
        |> auth(token_a)
        |> delete("/scim/v2/Users/#{identity_b.id}")
        |> json_response(404)

      assert body["status"] == "404"
      # B's membership is untouched — A's token never reached it.
      refute Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PUT active:true on an account-B server id → 404; B's suspension stands", %{
      conn: conn,
      token_a: token_a,
      provider_b: provider_b,
      account_b: account_b
    } do
      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|susp-b", email: "sb@acme.test"})

      id_b = user_resource_id(provider_b, "okta|susp-b")
      {:ok, _} = SSO.scim_update_user(provider_b, id_b, %SCIMUserUpdate{active: false})

      assert conn
             |> scim_put(token_a, "/scim/v2/Users/#{id_b}", %{"active" => true})
             |> json_response(404)

      # B stays suspended — A's reactivate never reached B's membership.
      assert Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PATCH active:true on an account-B server id → 404; B's suspension stands", %{
      conn: conn,
      token_a: token_a,
      provider_b: provider_b,
      account_b: account_b
    } do
      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|patch-b", email: "pb@acme.test"})

      id_b = user_resource_id(provider_b, "okta|patch-b")
      {:ok, _} = SSO.scim_update_user(provider_b, id_b, %SCIMUserUpdate{active: false})

      assert conn
             |> scim_patch(token_a, "/scim/v2/Users/#{id_b}", active_patch(true))
             |> json_response(404)

      assert Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end

    test "PATCH active:false on an account-B server id → 404; B's member stays active",
         %{conn: conn, token_a: token_a, provider_b: provider_b, account_b: account_b} do
      {:ok, %{user: user_b}} =
        SSO.scim_provision_user(provider_b, %{external_id: "okta|live-b", email: "lb@acme.test"})

      assert conn
             |> scim_patch(
               token_a,
               "/scim/v2/Users/#{user_resource_id(provider_b, "okta|live-b")}",
               active_patch(false)
             )
             |> json_response(404)

      # B's member is still active — A's deactivate never reached B.
      refute Accounts.peek_sync_membership(account_b.id, user_b.id).disabled_at
    end
  end

  # -- Full lifecycle round-trip ---------------------------------------

  describe "provisioning lifecycle" do
    setup do
      scim_provider(%{default_role: :admin})
    end

    test "POST → PATCH active:false → PATCH active:true → DELETE, asserting state at each step",
         %{conn: conn, token: token, provider: provider, account: account} do
      ext = "okta|lifecycle"

      # 1. Provision → active member, user + identity created.
      provisioned =
        conn
        |> scim_post(token, ~p"/scim/v2/Users", user_payload(ext, email: "life@acme.test"))
        |> json_response(201)

      assert provisioned["active"] == true
      id = provisioned["id"]
      assert Repo.valid_uuid?(id)
      refute id == ext

      {:ok, user} = Users.fetch_user_by_email("life@acme.test")
      membership = Accounts.peek_sync_membership(account.id, user.id)
      assert membership
      refute membership.disabled_at

      # 2. Deactivate → membership suspended, identity flagged inactive.
      deactivated =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/#{id}", active_patch(false))
        |> json_response(200)

      assert deactivated["active"] == false
      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # 3. Reactivate → membership reinstated.
      reactivated =
        conn
        |> scim_patch(token, ~p"/scim/v2/Users/#{id}", active_patch(true))
        |> json_response(200)

      assert reactivated["active"] == true
      refute Accounts.peek_sync_membership(account.id, user.id).disabled_at

      # 4. DELETE → access suspended, wire resource retired, person kept.
      assert conn |> auth(token) |> delete(~p"/scim/v2/Users/#{id}") |> response(204)

      assert Accounts.peek_sync_membership(account.id, user.id).disabled_at
      # The person and historical identity row persist, but the SCIM resource is gone.
      assert {:ok, _user} = Users.fetch_user_by_id(user.id)
      assert SSO.scim_fetch_user(provider, id) == {:error, :not_found}
    end

    test "`scim_active` drift is self-corrected on the next reconcile (re-POST)", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
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
      {:ok, reloaded} = SSO.scim_fetch_user(provider, user_resource_id(provider, "okta|drift"))
      assert reloaded.active
    end
  end

  # -- Read + list -----------------------------------------------------

  describe "GET /Users" do
    setup do
      scim_provider()
    end

    test "GET /Users/:id returns the resource; unknown id → 404", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|read", email: "read@acme.test"})

      body = conn |> auth(token) |> get(~p"/scim/v2/Users/#{identity.id}") |> json_response(200)
      assert body["externalId"] == "okta|read"

      # The same handle POST returned. A read used to hand back a bare identity,
      # which stores no email, so `userName` fell through to the opaque
      # externalId — one person with two handles depending on the verb.
      assert body["userName"] == "read@acme.test"

      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|read") |> json_response(404)
      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|missing") |> json_response(404)
    end

    test "the userName a create returns is the one a filter finds", %{
      conn: conn,
      token: token
    } do
      # An IdP's normal loop: create, then probe by the handle it got back. The
      # create echoed the email while the filter matched only `claims.email` —
      # which a SCIM-created identity never has — so the probe found nothing and
      # the directory re-created the same person every cycle.
      created =
        conn
        |> auth(token)
        |> post(
          ~p"/scim/v2/Users",
          user_payload("okta|round", user_name: "round@acme.test", email: "round@acme.test")
        )
        |> json_response(201)

      assert created["userName"] == "round@acme.test"

      filter = ~s|userName eq "#{created["userName"]}"|

      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=#{filter}")
        |> json_response(200)

      assert body["totalResults"] == 1
      assert [%{"externalId" => "okta|round"}] = body["Resources"]
    end

    test "GET /Users/:id is independent from the externalId correlation value", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{external_id: "okta|coalesce", email: "c@acme.test"})

      # Drop scim_external_id, leaving only provider_identifier set.
      {:ok, _} =
        identity |> Ecto.Changeset.change(scim_external_id: nil) |> Repo.update()

      body =
        conn
        |> auth(token)
        |> get("/scim/v2/Users/#{identity.id}")
        |> json_response(200)

      assert body["id"] == identity.id
      assert body["externalId"] == "okta|coalesce"

      # The retired externalId-addressed route does not resolve the same row.
      assert conn |> auth(token) |> get(~p"/scim/v2/Users/okta|coalesce") |> json_response(404)

      # The collection filter still uses the IdP correlation value.
      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?filter=externalId eq \"okta|coalesce\"")
        |> json_response(200)

      assert body["totalResults"] == 1
    end

    test "GET /Users with a userName filter returns just the match", %{
      conn: conn,
      token: token,
      provider: provider
    } do
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

    test "GET /Users with an externalId filter returns just the match", %{
      conn: conn,
      token: token,
      provider: provider
    } do
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
         %{conn: conn, token: token, provider: provider} do
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

    test "GET /Users declines a compound filter instead of answering it empty",
         %{conn: conn, token: token, provider: provider} do
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "a@acme.test"})

      # The unquoted value must not span whitespace. It used to, so this parsed
      # as the literal username "a@acme.test and active eq true" and answered 200
      # with zero results — and an IdP whose reconcile is filter-then-create-if-
      # empty responds to that by creating a duplicate identity. Groups already
      # declined the same shape, so the two routes disagreed about one filter.
      for filter <- [
            ~s|userName eq a@acme.test and active eq true|,
            ~s|userName eq "a@acme.test" and active eq true|
          ] do
        body =
          conn
          |> auth(token)
          |> get(~p"/scim/v2/Users?filter=#{filter}")
          |> json_response(400)

        assert body["scimType"] == "invalidFilter"
      end
    end

    test "GET /Users filter finds a user beyond the first page (the match runs in the query)",
         %{conn: conn, token: token, provider: provider} do
      # Provision the target first (so it's the oldest identity), then push it
      # past the page limit with 100 newer ones. A page-then-filter-in-memory
      # implementation would miss it; the query-level filter finds it wherever
      # it sits — without this, an IdP's existence probe re-creates a duplicate.
      {:ok, _target} = SSO.scim_provision_user(provider, %{external_id: "target@acme.test"})

      page_off_target(provider, 100)

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

    test "an UNQUOTED filter value is accepted (regex allows quoted or unquoted)", %{
      conn: conn,
      token: token,
      provider: provider
    } do
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

    test "an unfiltered collection reports its truthful total across stable pages", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      # One real provisioned identity plus 120 newer rows proves the first page
      # is bounded without pretending the collection contains only 100 users.
      {:ok, _anchor} = SSO.scim_provision_user(provider, %{external_id: "anchor@acme.test"})

      page_off_target(provider, 120)

      first = conn |> auth(token) |> get(~p"/scim/v2/Users") |> json_response(200)

      assert length(first["Resources"]) == 100
      assert first["totalResults"] == 121
      assert first["itemsPerPage"] == 100
      assert first["startIndex"] == 1

      second =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?startIndex=101&count=100")
        |> json_response(200)

      assert length(second["Resources"]) == 21
      assert second["totalResults"] == 121
      assert second["itemsPerPage"] == 21
      assert second["startIndex"] == 101

      first_ids = MapSet.new(first["Resources"], & &1["externalId"])
      second_ids = MapSet.new(second["Resources"], & &1["externalId"])

      assert MapSet.disjoint?(first_ids, second_ids)
      assert MapSet.size(MapSet.union(first_ids, second_ids)) == 121
    end

    test "count zero returns no resources and preserves the collection total", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      {:ok, _} = SSO.scim_provision_user(provider, %{external_id: "one@acme.test"})

      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?startIndex=0&count=0")
        |> json_response(200)

      assert body["Resources"] == []
      assert body["totalResults"] == 1
      assert body["itemsPerPage"] == 0
      assert body["startIndex"] == 1
    end

    test "malformed pagination is a typed SCIM error", %{conn: conn, token: token} do
      body =
        conn
        |> auth(token)
        |> get(~p"/scim/v2/Users?startIndex=first&count=many")
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end
  end

  # -- Discovery -------------------------------------------------------

  describe "discovery" do
    setup do
      scim_provider()
    end

    test "GET /ServiceProviderConfig is 200 behind auth and declares our support", %{
      conn: conn,
      token: token
    } do
      body = conn |> auth(token) |> get(~p"/scim/v2/ServiceProviderConfig") |> json_response(200)

      assert body["patch"]["supported"] == true
      assert body["filter"]["supported"] == true
      # The discovery document and collection parser share one owned cap.
      assert body["filter"]["maxResults"] == 100
      assert body["bulk"]["supported"] == false
      assert body["sort"]["supported"] == false
      assert body["etag"]["supported"] == false
      assert body["changePassword"]["supported"] == false
      assert [%{"type" => "oauthbearertoken", "primary" => true}] = body["authenticationSchemes"]
      # documentationUri + meta.location are built from the public base URL.
      base = Emisar.PublicUrl.base()
      assert body["documentationUri"] == "#{base}/docs/scim"
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

    test "GET /ResourceTypes lists both resources emisar actually serves", %{
      conn: conn,
      token: token
    } do
      body = conn |> auth(token) |> get(~p"/scim/v2/ResourceTypes") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]

      # Group used to be withheld here on the grounds that group sync is
      # push-only. But /Groups has a full route set, and a client that decides
      # what to push by reading discovery was told groups did not exist — so it
      # never sent one and every group→role mapping stayed unfed.
      types = Map.new(body["Resources"], &{&1["id"], &1})
      assert Map.keys(types) |> Enum.sort() == ["Group", "User"]

      assert types["User"]["endpoint"] == "/Users"
      assert types["User"]["schema"] == "urn:ietf:params:scim:schemas:core:2.0:User"
      assert types["User"]["meta"]["location"] == "/scim/v2/ResourceTypes/User"

      assert types["Group"]["endpoint"] == "/Groups"
      assert types["Group"]["schema"] == "urn:ietf:params:scim:schemas:core:2.0:Group"
      assert types["Group"]["meta"]["location"] == "/scim/v2/ResourceTypes/Group"

      assert body["totalResults"] == 2
      assert body["itemsPerPage"] == 2
    end

    test "each ResourceType and Schema is fetchable at the location it advertises", %{
      conn: conn,
      token: token
    } do
      # `meta.location` is a promise; RFC 7643 §6 gives each type its own URL.
      for id <- ["User", "Group"] do
        body = conn |> auth(token) |> get(~p"/scim/v2/ResourceTypes/#{id}") |> json_response(200)
        assert body["id"] == id
      end

      for urn <- [
            "urn:ietf:params:scim:schemas:core:2.0:User",
            "urn:ietf:params:scim:schemas:core:2.0:Group"
          ] do
        body = conn |> auth(token) |> get(~p"/scim/v2/Schemas/#{urn}") |> json_response(200)
        assert body["id"] == urn
      end

      assert conn |> auth(token) |> get(~p"/scim/v2/ResourceTypes/Nope") |> json_response(404)
      assert conn |> auth(token) |> get(~p"/scim/v2/Schemas/nope") |> json_response(404)
    end

    test "GET /Schemas declares the User schema's three attributes", %{conn: conn, token: token} do
      body = conn |> auth(token) |> get(~p"/scim/v2/Schemas") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      schemas = Map.new(body["Resources"], &{&1["id"], &1})
      user_schema = schemas["urn:ietf:params:scim:schemas:core:2.0:User"]
      assert user_schema["id"] == "urn:ietf:params:scim:schemas:core:2.0:User"

      group_schema = schemas["urn:ietf:params:scim:schemas:core:2.0:Group"]
      group_attrs = Map.new(group_schema["attributes"], &{&1["name"], &1})
      assert group_attrs["displayName"]["required"] == true
      assert group_attrs["members"]["multiValued"] == true

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
    test "success and error responses use the SCIM JSON media type", %{
      conn: conn
    } do
      %{token: token} = scim_provider()

      success = conn |> auth(token) |> get(~p"/scim/v2/ServiceProviderConfig")
      error = conn |> auth(token) |> get(~p"/scim/v2/Users/not-a-resource")
      unauthorized = get(conn, ~p"/scim/v2/Users")

      assert json_response(success, 200)
      assert json_response(error, 404)
      assert json_response(unauthorized, 401)

      for response <- [success, error, unauthorized] do
        assert get_resp_header(response, "content-type") == [
                 "application/scim+json; charset=utf-8"
               ]
      end
    end
  end

  describe "Resource.parse_pagination/1" do
    test "owns the defaults, normalization, and page cap" do
      assert {:ok, %{start_index: 1, count: 100}} = Resource.parse_pagination(%{})

      assert {:ok, %{start_index: 1, count: 0}} =
               Resource.parse_pagination(%{"startIndex" => "-5", "count" => "-1"})

      assert {:ok, %{start_index: 7, count: 100}} =
               Resource.parse_pagination(%{"startIndex" => "7", "count" => "1000"})
    end

    test "rejects values that are not whole base-10 integers" do
      assert Resource.parse_pagination(%{"startIndex" => "1.5"}) == {:error, :invalid_pagination}

      assert Resource.parse_pagination(%{"count" => "10x"}) == {:error, :invalid_pagination}
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

    test "full_name resolves displayName → assembled → formatted, in that order" do
      # displayName FIRST, and the order matters live: we serve `name.formatted`
      # back, so Okta echoes a stale one alongside the fresh displayName on the
      # next write. Preferring formatted meant a rename was accepted, reported
      # successful, and silently kept the old name.
      assert Resource.parse_user(%{
               "displayName" => "Fresh Name",
               "name" => %{"formatted" => "Stale Name", "givenName" => "Fresh"}
             })[:full_name] == "Fresh Name"

      # Without a displayName, the components win over a formatted value…
      assert Resource.parse_user(%{
               "name" => %{"formatted" => "Stale Name", "givenName" => "Ada", "familyName" => "L"}
             })[:full_name] == "Ada L"

      # …and formatted remains the fallback for a client that sends only it.
      assert Resource.parse_user(%{"name" => %{"formatted" => "Only Formatted"}})[:full_name] ==
               "Only Formatted"
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

      assert %{external_id: "okta|atoms"} = Resource.parse_user(payload)

      # Asserting these exact keys never became atoms, rather than snapshotting
      # the VM's global atom count, keeps the invariant deterministic: the count
      # moves whenever any other async test interns an atom, which fails here for
      # a reason that has nothing to do with the parser.
      for key <- Map.keys(payload), key != "externalId" do
        assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
      end
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
    |> Enum.each(&Fixtures.Memberships.force_role(&1, "admin"))
  end

  # Suppress unused-alias warnings — referenced via `~p` / fixtures.
  _ = {ApiKeys}
end

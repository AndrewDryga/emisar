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
  alias Emisar.{Repo, SSO}
  alias Emisar.SSO.IdentityProvider

  @scim_content_type "application/scim+json"
  @scim_string_limit 255
  @max_group_member_ids 5_000
  @max_patch_operations 100

  # Enterprise account + a SCIM-enabled provider. Returns the provider, its raw
  # bearer (shown once), the owner subject, and the account.
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

  # Provision a directory user through the domain and return its identity.
  defp provision(provider, external_id) do
    {:ok, %{identity: identity}} =
      SSO.scim_provision_user(provider, %{external_id: external_id, full_name: "Dir User"})

    identity
  end

  defp role_of(account_id, user_id),
    do: Fixtures.Memberships.fetch_membership(account_id, user_id).role

  # A SCIM Group payload as Okta/Entra send it.
  defp group_payload(external_id, member_external_ids, opts \\ []) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "externalId" => external_id,
      "displayName" => opts[:display] || external_id,
      "members" => Enum.map(member_external_ids, &%{"value" => &1})
    }
  end

  defp overlong_scim_id, do: String.duplicate("g", @scim_string_limit + 1)
  defp too_many_member_external_ids, do: for(n <- 1..(@max_group_member_ids + 1), do: "okta|#{n}")

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
    setup do
      scim_provider()
    end

    test "provisions a group and a mapped member's role becomes the mapped role", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
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

    test "an unmapped member in the group is tracked but its role is unchanged", %{
      conn: conn,
      token: token,
      provider: provider,
      account: account
    } do
      identity = provision(provider, "okta|nomap")

      # No mapping for grp-x → the member stays at the default role.
      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", group_payload("grp-x", ["okta|nomap"]))
        |> json_response(201)

      assert body["id"] == "grp-x"
      assert role_of(account.id, identity.user_id) == :viewer
    end

    test "a payload with no externalId/displayName → 400 SCIM error", %{conn: conn, token: token} do
      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", %{"members" => []})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["status"] == "400"
    end

    test "an overlong group externalId → 400 invalidValue", %{conn: conn, token: token} do
      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", group_payload(overlong_scim_id(), []))
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidValue"
    end

    test "an empty members set empties the group and renders members:[]", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|member")

      # Seed the group with one member at :admin.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|member"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # POST the same group with an empty members array → membership emptied, the
      # member resets to default_role, and the resource renders members:[].
      body =
        conn
        |> scim_send(token, :post, ~p"/scim/v2/Groups", group_payload("grp-adm", []))
        |> json_response(201)

      assert body["members"] == []
      assert role_of(account.id, identity.user_id) == :viewer
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
    setup do
      scim_provider()
    end

    # (add+remove delta) — the remove leg below uses the Okta
    # filtered-path `members[value eq "X"]` shape, so this also covers.
    test "add then remove members recomputes the affected roles", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
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

    test "an unsupported PATCH op → SCIM error, not a silent no-op", %{conn: conn, token: token} do
      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp", %{
          "Operations" => [%{"op" => "replace", "path" => "displayName", "value" => "Renamed"}]
        })
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidPath"
    end

    test "a PATCH with too many operations → 400 invalidValue", %{conn: conn, token: token} do
      operations =
        for _n <- 1..(@max_patch_operations + 1) do
          %{"op" => "add", "path" => "members", "value" => []}
        end

      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp", %{"Operations" => operations})
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH with too many aggregate member changes → 400 invalidValue", %{
      conn: conn,
      token: token
    } do
      operations =
        for op <- 1..@max_patch_operations do
          members =
            for member <- 1..51 do
              %{"value" => "okta|#{op}-#{member}"}
            end

          %{"op" => "add", "path" => "members", "value" => members}
        end

      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp", %{"Operations" => operations})
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "a whole-set `replace` of members short-circuits to a full upsert", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      keep = provision(provider, "okta|keep")
      incoming = provision(provider, "okta|incoming")

      # Seed the group with `keep` only.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-ops",
          member_external_ids: ["okta|keep"]
        })

      assert role_of(account.id, keep.user_id) == :operator
      assert role_of(account.id, incoming.user_id) == :viewer

      # A whole-set replace makes membership exactly [incoming] — keep is removed
      # (resets to default_role), incoming is added (gets the mapped role).
      replace_body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "members", "value" => [%{"value" => "okta|incoming"}]}
        ]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-ops", replace_body)
             |> json_response(200)

      assert role_of(account.id, incoming.user_id) == :operator
      assert role_of(account.id, keep.user_id) == :viewer
    end

    test "a PATCH replace with an overlong member id → 400 invalidValue", %{
      conn: conn,
      token: token
    } do
      replace_body = %{
        "Operations" => [
          %{"op" => "replace", "path" => "members", "value" => [%{"value" => overlong_scim_id()}]}
        ]
      }

      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-ops", replace_body)
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "a pathless add op carries the member ids in `value`", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|pathless")

      # No `path` — the members array rides in `value` (an accepted op shape).
      add_body = %{
        "Operations" => [%{"op" => "add", "value" => [%{"value" => "okta|pathless"}]}]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-adm", add_body)
             |> json_response(200)

      assert role_of(account.id, identity.user_id) == :admin
    end

    test "the op keyword is matched case-insensitively (`Add`)", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|caseop")

      add_body = %{
        "Operations" => [
          %{"op" => "Add", "path" => "members", "value" => [%{"value" => "okta|caseop"}]}
        ]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-adm", add_body)
             |> json_response(200)

      assert role_of(account.id, identity.user_id) == :admin
    end

    test "ops that resolve to an empty net delta → 400 invalidPath", %{conn: conn, token: token} do
      # An add op whose members array is empty resolves to {:delta, [], []} —
      # nothing to do, so an honest invalidPath, never a silent no-op.
      empty_body = %{"Operations" => [%{"op" => "add", "path" => "members", "value" => []}]}

      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-x", empty_body)
        |> json_response(400)

      assert body["scimType"] == "invalidPath"
    end

    test "a remove of a member not in the group is a no-op (200)", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      identity = provision(provider, "okta|stay")

      # Seed the group with `stay` at :admin.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|stay"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # Remove an externalId that was never in this group — the remove resolves to
      # no link, so it's a no-op: 200, and the seeded member is untouched.
      remove_body = %{
        "Operations" => [
          %{"op" => "remove", "path" => "members", "value" => [%{"value" => "okta|ghost"}]}
        ]
      }

      assert conn
             |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-adm", remove_body)
             |> json_response(200)

      assert role_of(account.id, identity.user_id) == :admin
    end

    test "a non-list `Operations` → 400 invalidValue", %{conn: conn, token: token} do
      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-x", %{"Operations" => "add members"})
        |> json_response(400)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
      assert body["scimType"] == "invalidValue"
    end

    test "a PATCH with no `Operations` key → 400 invalidSyntax", %{conn: conn, token: token} do
      body =
        conn
        |> scim_send(token, :patch, ~p"/scim/v2/Groups/grp-x", %{"displayName" => "Renamed"})
        |> json_response(400)

      assert body["scimType"] == "invalidSyntax"
    end

    test "an account-A token's group PATCH only affects account A", %{conn: conn} do
      %{token: token_a, provider: provider_a, subject: subject_a, account: account_a} =
        scim_provider()

      %{provider: provider_b, subject: subject_b, account: account_b} = scim_provider()

      # Same group id + :admin mapping in both accounts; a member with the SAME
      # external id provisioned in each.
      {:ok, _} =
        SSO.create_group_mapping(provider_a, %{external_group_id: "grp", role: :admin}, subject_a)

      {:ok, _} =
        SSO.create_group_mapping(provider_b, %{external_group_id: "grp", role: :admin}, subject_b)

      id_a = provision(provider_a, "okta|shared")
      id_b = provision(provider_b, "okta|shared")

      add_body = %{
        "Operations" => [
          %{"op" => "add", "path" => "members", "value" => [%{"value" => "okta|shared"}]}
        ]
      }

      assert conn
             |> scim_send(token_a, :patch, ~p"/scim/v2/Groups/grp", add_body)
             |> json_response(200)

      # A's member promoted; B's identically-named member resolves within
      # provider B only and is untouched.
      assert role_of(account_a.id, id_a.user_id) == :admin
      assert role_of(account_b.id, id_b.user_id) == :viewer
    end
  end

  # -- DELETE / PUT / GET ----------------------------------------------

  describe "DELETE / PUT / GET" do
    setup do
      scim_provider()
    end

    test "DELETE empties the group and recomputes (204)", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
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

    test "PUT replaces the group's membership (200)", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
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

    test "PUT rejects group member lists over the cap before replacing", %{
      conn: conn,
      token: token
    } do
      body =
        conn
        |> scim_send(
          token,
          :put,
          ~p"/scim/v2/Groups/grp-too-large",
          group_payload("grp-too-large", too_many_member_external_ids())
        )
        |> json_response(400)

      assert body["scimType"] == "invalidValue"
    end

    test "PUT with no externalId in the body keys on the path :id", %{
      conn: conn,
      token: token,
      provider: provider,
      subject: subject,
      account: account
    } do
      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-ops", role: :operator},
          subject
        )

      identity = provision(provider, "okta|pathkey")

      # The body carries members + displayName but NO externalId — parse falls
      # back to the path id ("grp-ops"), so the mapped role still applies.
      body =
        conn
        |> scim_send(token, :put, ~p"/scim/v2/Groups/grp-ops", %{
          "displayName" => "Operators",
          "members" => [%{"value" => "okta|pathkey"}]
        })
        |> json_response(200)

      assert body["id"] == "grp-ops"
      assert role_of(account.id, identity.user_id) == :operator
    end

    test "DELETE of an unknown/never-pushed group → 204 no-op", %{conn: conn, token: token} do
      # Upsert-to-empty on a group that was never pushed is a harmless no-op; the
      # upsert always succeeds, so DELETE answers 204 (idempotent).
      assert conn |> auth(token) |> delete(~p"/scim/v2/Groups/grp-never") |> response(204)
    end

    test "DELETE; a member also in another mapped group recomputes to the remaining highest",
         %{conn: conn, token: token, provider: provider, subject: subject, account: account} do
      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      {:ok, _} =
        SSO.create_group_mapping(
          provider,
          %{external_group_id: "grp-op", role: :operator},
          subject
        )

      identity = provision(provider, "okta|both")

      # The member is in BOTH groups → highest mapped role is :admin.
      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-adm",
          member_external_ids: ["okta|both"]
        })

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-op",
          member_external_ids: ["okta|both"]
        })

      assert role_of(account.id, identity.user_id) == :admin

      # DELETE the admin group → the member is still in the operator group, so the
      # recompute falls back to :operator (not the provider default), not :admin.
      assert conn |> auth(token) |> delete(~p"/scim/v2/Groups/grp-adm") |> response(204)
      assert role_of(account.id, identity.user_id) == :operator
    end

    test "GET /Groups returns an empty SCIM ListResponse (no group read)", %{
      conn: conn,
      token: token
    } do
      body = conn |> auth(token) |> get(~p"/scim/v2/Groups") |> json_response(200)

      assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      assert body["totalResults"] == 0
    end

    test "GET /Groups stays empty even after a group was pushed (no group read)", %{
      conn: conn,
      token: token,
      provider: provider
    } do
      provision(provider, "okta|x")

      {:ok, _} =
        SSO.scim_upsert_group(provider, %{
          external_id: "grp-pushed",
          member_external_ids: ["okta|x"]
        })

      # The membership is stored, but there is no SCIM Group read — the list is
      # still the empty stub (sync is push-only; SCIM-018 domain gap).
      body = conn |> auth(token) |> get(~p"/scim/v2/Groups") |> json_response(200)
      assert body["totalResults"] == 0
      assert body["Resources"] == []
    end

    test "GET /Groups/:id → 404 SCIM error (no group read)", %{conn: conn, token: token} do
      body = conn |> auth(token) |> get(~p"/scim/v2/Groups/grp-x") |> json_response(404)
      assert body["status"] == "404"
    end

    test "an account-A token's group DELETE only affects account A", %{conn: conn} do
      %{token: token_a, provider: provider_a, subject: subject_a, account: account_a} =
        scim_provider()

      %{provider: provider_b, subject: subject_b, account: account_b} = scim_provider()

      # Same group id + :admin mapping in both accounts, with an identically-named
      # member at :admin in each.
      id_a = seed_admin_group_member(provider_a, subject_a, "grp", "okta|shared")
      id_b = seed_admin_group_member(provider_b, subject_b, "grp", "okta|shared")
      assert role_of(account_a.id, id_a.user_id) == :admin
      assert role_of(account_b.id, id_b.user_id) == :admin

      # DELETE the group with A's token only — it empties A's group (member resets
      # to default_role) and never touches B's identically-named group.
      assert conn |> auth(token_a) |> delete(~p"/scim/v2/Groups/grp") |> response(204)

      assert role_of(account_a.id, id_a.user_id) == :viewer
      assert role_of(account_b.id, id_b.user_id) == :admin
    end
  end

  # -- Best-effort: a refused recompute is held, not fatal -------------

  describe "POST /Groups best-effort recompute" do
    @tag capture_log: true
    test "a per-member recompute refusal is held — the push still returns 201", %{conn: conn} do
      %{token: token, provider: provider, subject: subject, account: account} = scim_provider()

      {:ok, _} =
        SSO.create_group_mapping(provider, %{external_group_id: "grp-adm", role: :admin}, subject)

      kept = provision(provider, "okta|kept")
      %{membership: gone_membership} = provision_with_membership(provider, "okta|gone")

      # One member was removed from the team (membership soft-deleted) while the
      # identity lived on, so its recompute refuses with :not_found. The push must
      # still succeed (best-effort, the IdP re-drives) — never a 4xx/5xx.
      {:ok, _} =
        gone_membership |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

      assert conn
             |> scim_send(
               token,
               :post,
               ~p"/scim/v2/Groups",
               group_payload("grp-adm", ["okta|kept", "okta|gone"])
             )
             |> json_response(201)

      # The healthy member was still recomputed — one refusal didn't abort the push.
      assert role_of(account.id, kept.user_id) == :admin
    end
  end

  # Map a group→:admin, provision a member, and push them into it — leaving the
  # member at :admin. Returns the member's identity (for cross-provider scoping
  # assertions where the same external id is seeded in two providers).
  defp seed_admin_group_member(provider, subject, group_id, external_id) do
    {:ok, _} =
      SSO.create_group_mapping(provider, %{external_group_id: group_id, role: :admin}, subject)

    identity = provision(provider, external_id)

    {:ok, _} =
      SSO.scim_upsert_group(provider, %{external_id: group_id, member_external_ids: [external_id]})

    identity
  end

  # Provision and return the full identity + membership (for the soft-delete
  # refusal test).
  defp provision_with_membership(provider, external_id) do
    {:ok, %{identity: identity, membership: membership}} =
      SSO.scim_provision_user(provider, %{external_id: external_id, full_name: "Dir User"})

    %{identity: identity, membership: membership}
  end
end

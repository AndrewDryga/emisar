defmodule EmisarWeb.SSOSettingsLiveTest do
  @moduledoc """
  The enterprise SSO settings page. Access is plan-gated (Enterprise) AND
  permission-gated (`manage_sso`, owners/admins): an enterprise admin sees the
  config + can add a connection; a non-enterprise account and a non-admin member
  both see the Enterprise upsell instead of a crash.
  """
  use EmisarWeb.ConnCase, async: true

  alias Emisar.Repo
  alias Emisar.SSO
  alias Emisar.SSO.{IdentityProvider, LinkRequest, UserIdentity}

  defp make_viewer(user) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Emisar.Fixtures.force_membership_role(membership, "viewer")
  end

  defp insert_link_request(provider, attrs) do
    sub = Map.get(Map.new(attrs), :provider_identifier, "okta|pending")

    attrs =
      Map.merge(
        %{
          provider_identifier: sub,
          email: "pending@acme.test",
          full_name: "Pending Person",
          claims: %{"sub" => sub, "email" => "pending@acme.test", "email_verified" => true}
        },
        Map.new(attrs)
      )

    {:ok, request} =
      Repo.insert(LinkRequest.Changeset.create(provider.account_id, provider.id, attrs))

    request
  end

  defp identity_bound?(provider, sub) do
    UserIdentity.Query.not_deleted()
    |> UserIdentity.Query.by_provider_and_identifier(provider.id, sub)
    |> Repo.exists?()
  end

  defp insert_provider(account, attrs) do
    attrs =
      Map.merge(
        %{
          kind: :okta,
          name: "Acme Okta",
          issuer: "https://idp.test",
          client_id: "cid",
          client_secret: "secret",
          enabled: true
        },
        Map.new(attrs)
      )

    {:ok, provider} = Repo.insert(IdentityProvider.Changeset.create(account.id, attrs))
    provider
  end

  describe "as an enterprise admin" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "renders the config surface, not the upsell", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")

      assert html =~ "Add connection"
      refute html =~ "Enterprise feature"

      # Adding a connection is its own view (with the per-provider setup guide).
      {:ok, _lv, new_html} = live(conn, ~p"/app/settings/sso/new")
      assert new_html =~ "Add an identity provider"
      assert new_html =~ "/sign_in/sso/callback"
    end

    test "lists existing connections", %{conn: conn, account: account} do
      _provider = insert_provider(account, %{name: "Acme Okta"})

      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")

      assert html =~ "Acme Okta"
      assert html =~ "Enabled"
    end

    test "creates a connection through the form, then returns to the list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso/new")

      lv
      |> form("#provider_form", %{
        "provider" => %{
          "kind" => "okta",
          "name" => "Work Okta",
          "issuer" => "https://work.okta.com",
          "client_id" => "abc",
          "client_secret" => "shh",
          "default_role" => "viewer"
        }
      })
      |> render_submit()

      # Adding is its own view; a successful create navigates back to the list.
      assert_redirect(lv, ~p"/app/settings/sso")

      assert IdentityProvider.Query.not_deleted()
             |> IdentityProvider.Query.ordered_by_name()
             |> Repo.all()
             |> Enum.any?(&(&1.name == "Work Okta"))

      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")
      assert html =~ "Work Okta"
    end

    test "opens the inline edit form without leaking the stored secret", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{client_secret: "super-secret-value-xyz"})
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      # The create form and this edit form coexist in the DOM; opening the
      # edit form must not collide their input IDs (a duplicate-id crash) and
      # must never render the stored, write-only client_secret back.
      html = render_hook(lv, "start_edit", %{"id" => provider.id})

      assert html =~ "edit-provider-#{provider.id}"
      assert html =~ "Leave blank to keep current"
      refute html =~ "super-secret-value-xyz"
    end

    test "edits a connection's display name through the inline form", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Old Name"})
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")
      _ = render_hook(lv, "start_edit", %{"id" => provider.id})

      html =
        lv
        |> form("#edit-provider-#{provider.id}", %{
          "provider_id" => provider.id,
          "provider" => %{
            "kind" => "okta",
            "name" => "New Name",
            "issuer" => "https://idp.test",
            "client_id" => "cid"
          }
        })
        |> render_submit()

      assert html =~ "New Name"
      assert html =~ "Connection updated."
      refute html =~ "Old Name"
    end

    test "an invalid issuer renders inline on the field, not in a flash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso/new")

      html =
        lv
        |> form("#provider_form", %{
          "provider" => %{
            "kind" => "okta",
            "name" => "Bad",
            "issuer" => "http://insecure.test",
            "client_id" => "abc"
          }
        })
        |> render_submit()

      assert html =~ "must be an https URL"
    end
  end

  describe "directory sync (SCIM)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{name: "Acme Okta"})
      %{conn: conn, user: user, account: account, provider: provider}
    end

    test "enable mints a token shown once + the SCIM base URL", %{conn: conn, provider: provider} do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      html = render_click(lv, "enable_scim", %{"id" => provider.id})

      assert html =~ "Directory sync enabled."
      assert html =~ "shown only once"
      assert html =~ "/scim/v2"
      # The freshly-minted ems- token is rendered exactly once, in the reveal.
      assert html =~ "ems-"
      # The IdP-side SCIM setup steps appear once sync is on.
      assert html =~ "Point your IdP at this connection"
      assert html =~ "externalId"

      reloaded = Repo.reload!(provider)
      assert reloaded.scim_enabled
      assert reloaded.scim_token_prefix
    end

    test "the token is never rendered back after dismissal / reload", %{
      conn: conn,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      shown = render_click(lv, "enable_scim", %{"id" => provider.id})
      [_, token | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, shown) || [nil, nil]
      assert is_binary(token)

      # Dismiss the reveal — the raw token must be gone from the DOM.
      dismissed = render_click(lv, "dismiss_scim_token", %{})
      refute dismissed =~ token

      # And a fresh mount never re-renders it (write-only, like client_secret).
      {:ok, _lv2, remounted} = live(conn, ~p"/app/settings/sso")
      refute remounted =~ token
      # Directory sync still shows as on, just without the secret.
      assert remounted =~ "Directory sync (SCIM)"
    end

    test "rotate issues a new token; disable turns sync off", %{conn: conn, provider: provider} do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      first = render_click(lv, "enable_scim", %{"id" => provider.id})
      [_, token1 | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, first)

      rotated = render_click(lv, "rotate_scim", %{"id" => provider.id})
      assert rotated =~ "SCIM token rotated."
      [_, token2 | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, rotated)
      refute token1 == token2

      disabled = render_click(lv, "disable_scim", %{"id" => provider.id})
      assert disabled =~ "Directory sync disabled."
      refute disabled =~ token2
      refute Repo.reload!(provider).scim_enabled
    end

    test "a non-admin viewer cannot enable directory sync", %{
      conn: conn,
      user: user,
      provider: provider
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly.
      _ = render_click(lv, "enable_scim", %{"id" => provider.id})
      refute Repo.reload!(provider).scim_enabled
    end
  end

  describe "group → role mapping" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      owner = Emisar.Fixtures.subject_for(user, account)
      provider = insert_provider(account, %{name: "Acme Okta"})
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)
      %{conn: conn, user: user, account: account, provider: provider, owner: owner}
    end

    test "creates, lists, and deletes a group mapping", %{
      conn: conn,
      provider: provider,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      html =
        lv
        |> form("#create-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "mapping" => %{
            "external_group_id" => "00g-admins",
            "external_group_display" => "Admins",
            "role" => "admin"
          }
        })
        |> render_submit()

      assert html =~ "Group mapping added."
      # The row renders with its display + role.
      assert html =~ "Admins"
      assert html =~ "00g-admins"

      {:ok, [mapping], _meta} = SSO.list_group_mappings(provider, owner)

      # Delete it — the gated event removes the row.
      deleted = render_click(lv, "delete_mapping", %{"id" => mapping.id})
      assert deleted =~ "Group mapping deleted."

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, owner)
    end

    test "the role select never offers Owner; a forced owner mapping is rejected inline", %{
      conn: conn,
      provider: provider,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      # The mapping role <select> has Admin/Operator/Viewer but no Owner — scope
      # to the mapping create form so the provider form's own Owner option (its
      # default-role select does include Owner) doesn't match.
      mapping_form = lv |> element("#create-mapping-#{provider.id}") |> render()
      assert mapping_form =~ ~r/<option[^>]*>Admin<\/option>/
      refute mapping_form =~ ~r/<option[^>]*>Owner<\/option>/

      # A crafted submit with role=owner (pushed directly, bypassing the select
      # whose options never include owner) is rejected by the changeset and the
      # error surfaces inline — no mapping is created.
      rejected =
        render_submit(lv, "create_mapping", %{
          "provider_id" => provider.id,
          "mapping" => %{"external_group_id" => "grp-owner", "role" => "owner"}
        })

      assert rejected =~ "directory sync cannot grant owner"
      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, owner)
    end

    test "a non-admin viewer cannot create a group mapping", %{
      conn: conn,
      user: user,
      provider: provider,
      owner: owner
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly.
      _ =
        render_click(lv, "create_mapping", %{
          "provider_id" => provider.id,
          "mapping" => %{"external_group_id" => "grp", "role" => "admin"}
        })

      # No mapping was created (read it back through the pre-demotion owner subject).
      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, owner)
    end
  end

  describe "manual link requests" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      owner = Emisar.Fixtures.subject_for(user, account)

      provider =
        insert_provider(account, %{
          name: "Manual Okta",
          provisioner: :manual,
          default_role: :operator
        })

      %{conn: conn, user: user, account: account, provider: provider, owner: owner}
    end

    test "the connection form offers the manual provisioning mode", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso/new")

      assert html =~ "New-user provisioning"
      assert html =~ "an admin approves each new user"
    end

    test "lists pending requests with the captured identity", %{conn: conn, provider: provider} do
      _ =
        insert_link_request(provider, %{
          provider_identifier: "okta|dana",
          full_name: "Dana Operator",
          email: "dana@acme.test"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")

      assert html =~ "Pending access requests"
      assert html =~ "Dana Operator"
      assert html =~ "okta|dana"
    end

    test "approve provisions the captured identity + clears the request", %{
      conn: conn,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|appr"})
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      html = render_click(lv, "approve_request", %{"id" => request.id})

      assert html =~ "approved"
      assert identity_bound?(provider, "okta|appr")
      assert {:ok, [], _meta} = SSO.list_link_requests(provider, owner)
    end

    test "dismiss removes the request without provisioning", %{
      conn: conn,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|dis"})
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      html = render_click(lv, "dismiss_request", %{"id" => request.id})

      assert html =~ "dismissed"
      refute identity_bound?(provider, "okta|dis")
      assert {:ok, [], _meta} = SSO.list_link_requests(provider, owner)
    end

    test "a non-admin viewer cannot approve a request", %{
      conn: conn,
      user: user,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|vw"})
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/settings/sso")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly — the request stays pending.
      _ = render_click(lv, "approve_request", %{"id" => request.id})

      refute identity_bound?(provider, "okta|vw")
      assert {:ok, [_still_pending], _meta} = SSO.list_link_requests(provider, owner)
    end
  end

  describe "as a non-enterprise account" do
    test "shows the Enterprise upsell instead of the config", %{conn: conn} do
      {conn, _user, _account} = register_and_log_in(conn, %{account: %{plan: "team"}})

      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")

      assert html =~ "Single sign-on is an Enterprise feature"
      assert html =~ "See plans"
      refute html =~ "Add an identity provider"
    end
  end

  describe "as a non-admin member" do
    test "an enterprise viewer is denied the config and sees the upsell", %{conn: conn} do
      {conn, user, _account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      _ = make_viewer(user)

      {:ok, _lv, html} = live(conn, ~p"/app/settings/sso")

      assert html =~ "Single sign-on is an Enterprise feature"
      refute html =~ "Add an identity provider"
    end
  end
end

defmodule EmisarWeb.SSOSettingsLiveTest do
  @moduledoc """
  The SSO settings pages — Add a connection (`/settings/sso/new`) and a
  per-connection detail (`/settings/sso/:id`: status, edit, directory sync,
  group→role mapping). The old overview at `/settings/sso` folded into the Team
  page and now redirects there. Access is plan-gated (Team for OIDC, Enterprise
  for SCIM) AND permission-gated (`manage_sso`, owners/admins): a non-admin member
  or a free account sees the upsell instead of a crash, and a cross-account
  connection id reads as not found (→ Team).
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Accounts
  alias Emisar.Repo
  alias Emisar.SSO
  alias Emisar.SSO.IdentityProvider

  defp make_viewer(user) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Fixtures.Memberships.force_role(membership, "viewer")
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

  defp mark_sign_in_verified(provider, user) do
    Fixtures.SSO.create_user_identity(%{
      account_id: provider.account_id,
      provider_id: provider.id,
      user_id: user.id,
      created_by: :user,
      provisioned_via: :oidc_link
    })

    digest =
      [
        provider.kind,
        provider.issuer,
        provider.client_id,
        provider.client_secret,
        provider.identifier_claim,
        provider.allowed_email_domain
      ]
      |> :erlang.term_to_binary()
      |> Emisar.Crypto.hash()

    provider
    |> IdentityProvider.Changeset.verify_sign_in(user.id, digest)
    |> Repo.update!()
  end

  defp sync_numbered_groups(provider, count) do
    for n <- 1..count do
      suffix = n |> Integer.to_string() |> String.pad_leading(2, "0")
      sync_group(provider, "grp-#{suffix}", "Group #{suffix}")
    end
  end

  defp sync_group(provider, external_group_id, display) do
    {:ok, group} =
      SSO.scim_upsert_group(provider, %{
        external_id: external_group_id,
        display: display,
        member_ids: []
      })

    group
  end

  defp refresh_directory(lv) do
    {attempt, provider_id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
    send(lv.pid, {:refresh_directory, attempt, provider_id})
    render(lv)
  end

  describe "connection refresh and fixed identity fields" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})

      %{
        conn: conn,
        user: user,
        account: account,
        provider: provider,
        subject: Fixtures.Subjects.subject_for(user, account)
      }
    end

    test "directory pushes refresh members and groups without replacing a mapping draft or token",
         %{
           conn: conn,
           account: account,
           provider: provider,
           subject: subject
         } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "enable_scim", %{"id" => provider.id})
      provider = Repo.reload!(provider)
      chosen = sync_group(provider, "chosen", "Chosen group")
      render_click(lv, "add_mapping_form", %{})
      render_click(lv, "select_group", %{"scope" => "role", "group_id" => chosen.id})

      lv
      |> form("#create-mapping-#{provider.id}", %{"mapping" => %{"role" => "operator"}})
      |> render_change()

      before = :sys.get_state(lv.pid).socket.assigns
      assert is_binary(before.scim_token.token)
      sync_group(provider, "arrived", "New directory group")

      {:ok, _member} =
        SSO.scim_provision_user(provider, %{
          external_id: "directory-new-member",
          email: "directory-new@example.com",
          full_name: "New Directory Member"
        })

      html = refresh_directory(lv)
      assert html =~ "New Directory Member"
      assert html =~ "directory-new@example.com"
      assert html =~ "New directory group"
      refute html =~ "directory-new-member"
      after_refresh = :sys.get_state(lv.pid).socket.assigns
      assert after_refresh.mapping_form.params == before.mapping_form.params
      assert after_refresh.group_pickers == before.group_pickers
      assert after_refresh.scim_token == before.scim_token
      assert after_refresh.adding_mapping

      {:ok, _provider, _token} = SSO.rotate_scim_token(provider, subject)
      refresh_directory(lv)
      assert is_nil(:sys.get_state(lv.pid).socket.assigns.scim_token)
      refute has_element?(lv, "#scim-token-#{provider.id}")
    end

    test "external enable, disable, and re-enable seed usable forms", %{
      conn: conn,
      account: account,
      provider: provider,
      subject: subject
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      {:ok, provider, _token} = SSO.enable_scim(provider, subject)
      refresh_directory(lv)
      render_click(lv, "add_mapping_form", %{})
      assert has_element?(lv, "#create-mapping-#{provider.id}")

      {:ok, provider} = SSO.disable_scim(provider, subject)
      refresh_directory(lv)
      refute has_element?(lv, "#create-mapping-#{provider.id}")

      {:ok, _provider, _token} = SSO.enable_scim(provider, subject)
      refresh_directory(lv)
      render_click(lv, "add_mapping_form", %{})
      group = sync_group(provider, "restored-group", "Restored group")
      refresh_directory(lv)
      render_click(lv, "edit_group_access", %{"group_id" => group.id})
      assert has_element?(lv, "#create-mapping-#{provider.id}")
      assert has_element?(lv, "#edit-group-access-#{group.id}")
    end

    test "refresh rechecks plan entitlement without needing a new socket", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")
      refresh_directory(lv)
      refute :sys.get_state(lv.pid).socket.assigns.can_configure?
      refute :sys.get_state(lv.pid).socket.assigns.can_configure_directory_sync?
    end

    test "stale ticks cannot refresh another connection or an edit form", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      {attempt, id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
      other = insert_provider(account, %{kind: :entra, name: "Other connection"})
      render_patch(lv, ~p"/app/#{account}/settings/sso/#{other.id}")
      send(lv.pid, {:refresh_directory, attempt, id})
      render(lv)
      assert :sys.get_state(lv.pid).socket.assigns.provider.id == other.id

      {attempt, id, _timer} = :sys.get_state(lv.pid).socket.assigns.directory_refresh
      render_patch(lv, ~p"/app/#{account}/settings/sso/#{other.id}/edit")
      send(lv.pid, {:refresh_directory, attempt, id})
      render(lv)
      assert is_nil(:sys.get_state(lv.pid).socket.assigns.directory_refresh)
      assert has_element?(lv, "form#edit-provider-#{other.id}")
    end

    test "a bound identity locks issuer, client ID, and claim, but leaves secret rotation available",
         %{
           conn: conn,
           account: account,
           user: user,
           provider: provider
         } do
      path = ~p"/app/#{account}/settings/sso/#{provider.id}/edit"
      {:ok, lv, _html} = live(conn, path)

      for field <- ~w(issuer client_id identifier_claim) do
        refute has_element?(lv, "[name='provider[#{field}]'][disabled]")
      end

      mark_sign_in_verified(provider, user)
      render_patch(lv, path <> "?reload=1")

      for field <- ~w(issuer client_id identifier_claim) do
        assert has_element?(lv, "[name='provider[#{field}]'][disabled]")
      end

      assert has_element?(lv, "input[name='provider[client_secret]']:not([disabled])")
    end
  end

  describe "as an enterprise admin" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "the overview /settings/sso now redirects to Team's anchored SSO card",
         %{conn: conn, account: account} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/app/#{account}/settings/sso")

      # The fragment matches the Team page's Single sign-on card id, so docs
      # deep-links and old bookmarks land at the section, not the page top.
      assert to == ~p"/app/#{account}/settings/team" <> "#single-sign-on"
    end

    test "Add a connection is its own page with the per-provider setup guide",
         %{conn: conn, account: account} do
      {:ok, lv, new_html} = live(conn, ~p"/app/#{account}/settings/sso/new")
      assert new_html =~ "Add connection"
      refute new_html =~ "Add an identity provider"
      assert new_html =~ "Member access"
      refute new_html =~ "User provisioning"
      assert new_html =~ "/sign_in/sso/callback"
      assert new_html =~ "Check issuer"
      assert new_html =~ "stay disabled until you save them and verify a real sign-in"
      refute new_html =~ ~s(name="provider[enabled]")

      assert has_element?(
               lv,
               "#create-provider[phx-hook='PendingButton'][phx-disable-with='Saving...']"
             )

      assert has_element?(
               lv,
               "#test-provider[phx-hook='PendingButton'][phx-disable-with='Testing…']"
             )
    end

    test "creates a connection through the form, then lands on its detail", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

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

      created =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.ordered_by_name()
        |> Repo.all()
        |> Enum.find(&(&1.name == "Work Okta"))

      assert created
      # A successful create lands on the new connection's detail, where the
      # next-steps (test a sign-in, enable directory sync) live.
      assert_redirect(lv, ~p"/app/#{account}/settings/sso/#{created.id}")

      {:ok, detail_lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{created.id}")
      assert html =~ "Work Okta"

      assert has_element?(
               detail_lv,
               ~s(a[href="/app/#{account.slug}/audit?target_kind=identity_provider&target_id=#{created.id}"]),
               "View activity"
             )
    end

    test "picking a fixed-issuer provider prefills its issuer", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      html =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "google_workspace", "issuer" => ""}})
        |> render_change()

      # Google's issuer is always the same value — the field fills it in rather
      # than making the operator hunt for it.
      assert html =~ ~s(value="https://accounts.google.com")
    end

    test "JumpCloud requires a region and saves the selection", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      lv
      |> form("#provider_form", %{"provider" => %{"kind" => "google_workspace"}})
      |> render_change()

      lv
      |> form("#provider_form", %{"provider" => %{"kind" => "jumpcloud"}})
      |> render_change(%{"_target" => ["provider", "kind"]})

      assert has_element?(
               lv,
               "select[name='provider[issuer]'] option[value='']",
               "Select a region"
             )

      refute has_element?(lv, "select[name='provider[issuer]'] option[selected]:not([value=''])")
      refute has_element?(lv, "input[name='provider[issuer]']")

      for {label, issuer} <- [
            {"United States", "https://oauth.id.jumpcloud.com/"},
            {"Europe", "https://oauth.id.eu.jumpcloud.com/"},
            {"India", "https://oauth.id.in.jumpcloud.com/"}
          ] do
        assert has_element?(
                 lv,
                 "select[name='provider[issuer]'] option[value='#{issuer}']",
                 label
               )
      end

      assert lv |> element("#test-provider") |> render_click() =~
               "Select a JumpCloud region first."

      lv
      |> form("#provider_form", %{
        "provider" => %{"issuer" => "https://oauth.id.eu.jumpcloud.com/"}
      })
      |> render_change()

      assert has_element?(
               lv,
               "select[name='provider[issuer]'] option[value='https://oauth.id.eu.jumpcloud.com/'][selected]"
             )

      lv
      |> form("#provider_form", %{
        "provider" => %{
          "name" => "European JumpCloud",
          "client_id" => "eu-client",
          "client_secret" => "eu-secret"
        }
      })
      |> render_submit()

      created =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.by_account_id(account.id)
        |> Repo.one!()

      assert created.kind == :jumpcloud
      assert created.issuer == "https://oauth.id.eu.jumpcloud.com/"
      refute created.enabled
      assert_redirect(lv, ~p"/app/#{account}/settings/sso/#{created.id}")
    end

    test "JumpCloud retains its region and locks the select after an identity is linked", %{
      conn: conn,
      account: account,
      user: user
    } do
      provider =
        insert_provider(account, %{
          kind: :jumpcloud,
          issuer: "https://oauth.id.jumpcloud.com/"
        })

      path = ~p"/app/#{account}/settings/sso/#{provider.id}/edit"
      {:ok, lv, _html} = live(conn, path)

      assert has_element?(lv, "select[name='provider[issuer]']:not([disabled])")

      assert has_element?(
               lv,
               "select[name='provider[issuer]'] option[value='https://oauth.id.jumpcloud.com/'][selected]"
             )

      mark_sign_in_verified(provider, user)
      render_patch(lv, path <> "?reload=1")

      assert has_element?(lv, "select[name='provider[issuer]'][disabled]")

      assert has_element?(
               lv,
               "select[name='provider[issuer]'] option[value='https://oauth.id.jumpcloud.com/'][selected]"
             )
    end

    test "the default-role picker is radio cards with per-role descriptions", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      assert html =~ ~s(name="provider[default_role]")
      assert html =~ ~s(type="radio")
      # A role's shared description renders on its card (viewer, here).
      assert html =~ "Viewers have read-only access across runs"
      assert html =~ ~s(name="provider[default_runner_access_mode]")

      assert has_element?(
               lv,
               "input[name='provider[default_runner_access_mode]'][value='none']:checked"
             )

      refute html =~ "You can grant only packs within your own access."
    end

    test "pack grant fields explain when the admin's own pack access is limited", %{
      conn: _conn,
      account: account
    } do
      admin = Fixtures.Users.create_user()

      membership =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: admin.id,
          role: "admin"
        )

      {:ok, restricted} = Accounts.RunnerAccess.new(:all, [], [], :restricted, ["postgres"])
      Fixtures.Memberships.force_runner_access(membership, restricted)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_user(admin)
        |> live(~p"/app/#{account}/settings/sso/new")

      changed =
        lv
        |> form("#provider_form", %{
          "provider" => %{"default_runner_access_mode" => "all"}
        })
        |> render_change()

      assert changed =~ "You can grant only packs within your own access."
    end

    test "selected provider access reveals quietly and validates on submit", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      changed =
        lv
        |> form("#provider_form", %{
          "provider" => %{"default_runner_access_mode" => "restricted"}
        })
        |> render_change()

      refute changed =~ "Choose at least one runner group or runner for selected access."

      invalid =
        lv
        |> form("#provider_form", %{
          "provider" => %{"default_runner_access_mode" => "restricted"}
        })
        |> render_submit()

      assert invalid =~ "Choose at least one runner group or runner for selected access."
    end

    test "a rejected selection keeps what was typed and stays removable", %{
      conn: conn,
      account: account
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # A group the account no longer has — the selection an operator's stale
      # picker (or a crafted submission) still names.
      params = %{
        "provider" => %{
          "kind" => "okta",
          "name" => "Acme Okta",
          "issuer" => "https://idp.test",
          "client_id" => "cid",
          "client_secret" => "secret",
          "default_runner_access_mode" => "restricted",
          "default_runner_scope" => ["group:retired-fleet"]
        }
      }

      html = render_submit(lv, "create", params)

      assert html =~ "Choose at least one runner group or runner for selected access."
      assert html =~ ~s(value="Acme Okta")
      assert html =~ ~s(value="https://idp.test")
      assert html =~ "retired-fleet"
      assert html =~ "unavailable"

      # Still ticked and still enabled, so unticking it is how the operator
      # moves on from a selection the account can no longer honor.
      assert has_element?(
               lv,
               ~s|input[name="provider[default_runner_scope][]"][value="group:retired-fleet"][checked]:not([disabled])|
             )

      refute IdentityProvider.Query.not_deleted()
             |> IdentityProvider.Query.by_account_id(account.id)
             |> Repo.one()
    end

    test "picking a provider type doesn't accuse the operator of blank fields", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # A `phx-change` carries every field in the form, so marking the changeset
      # validated on change used to put "can't be blank" under Issuer URL the
      # moment a provider was picked — before the cursor had ever been in it.
      # `_target` is what a browser sends to say which field was edited; the test
      # helper omits it unless asked, so pass it or this proves nothing.
      changed =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "entra"}})
        |> render_change(%{"_target" => ["provider", "kind"]})

      refute changed =~ "can&#39;t be blank"

      # Clearing a field the operator IS editing still reports blank at once —
      # the quiet is for fields they have not reached, not for the one in hand.
      cleared =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "entra", "name" => ""}})
        |> render_change(%{"_target" => ["provider", "name"]})

      assert cleared =~ "can&#39;t be blank"

      # A value they DID type still reports straight away: that is feedback about
      # their own input, not an accusation about input they have not given yet.
      typed =
        lv
        |> form("#provider_form", %{
          "provider" => %{"kind" => "entra", "issuer" => "http://login.example.com"}
        })
        |> render_change()

      assert typed =~ "must be an https URL"

      # And suppressing the error on change must not skip the validation: a blank
      # required field still fails on submit.
      submitted =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "entra", "issuer" => ""}})
        |> render_submit()

      assert submitted =~ "can&#39;t be blank"
    end

    test "the edit page renders the form without leaking the stored secret", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{client_secret: "super-secret-value-xyz"})

      # The dedicated edit page must never render the stored, write-only
      # client_secret back — the field is blank ("leave to keep").
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      assert html =~ "edit-provider-#{provider.id}"
      assert html =~ "Leave blank to keep current"
      refute html =~ "super-secret-value-xyz"

      assert has_element?(
               lv,
               "#save-provider-#{provider.id}[phx-hook='PendingButton'][phx-disable-with='Saving...']"
             )
    end

    test "the edit page shows provider type read-only — it's create-only", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{kind: :okta})
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      # kind is create-only (update/2 never casts it); the edit form must not offer
      # an editable select that would silently drop the change.
      refute html =~ ~s(name="provider[kind]")
      assert html =~ "Add a new connection to use a different provider"
    end

    test "editing one field doesn't accuse the operator of blank ones", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Old Name"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      # Same contract as the create form: a `phx-change` carries EVERY field, so
      # the edit handler used to mark the changeset validated raw and report
      # "can't be blank" for fields the operator had not reached — including the
      # client secret, which is blank ON PURPOSE here ("leave to keep").
      changed =
        lv
        |> form("#edit-provider-#{provider.id}", %{
          "provider_id" => provider.id,
          "provider" => %{"name" => "New Name"}
        })
        |> render_change(%{"_target" => ["provider", "name"]})

      refute changed =~ "can&#39;t be blank"

      # The field they ARE editing still reports blank the moment it is cleared.
      cleared =
        lv
        |> form("#edit-provider-#{provider.id}", %{
          "provider_id" => provider.id,
          "provider" => %{"name" => ""}
        })
        |> render_change(%{"_target" => ["provider", "name"]})

      assert cleared =~ "can&#39;t be blank"
    end

    test "edits a connection's display name from the edit page", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Old Name"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      lv
      |> form("#edit-provider-#{provider.id}", %{
        "provider_id" => provider.id,
        "provider" => %{
          "name" => "New Name",
          "issuer" => "https://idp.test",
          "client_id" => "cid"
        }
      })
      |> render_submit()

      # Saving returns to the connection's detail page; the row is updated.
      assert_redirect(lv, ~p"/app/#{account}/settings/sso/#{provider.id}")
      assert Repo.reload!(provider).name == "New Name"
    end

    test "the setup guide shows a FIXED callback URI, never an operator input", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # The redirect/callback URI the operator registers at their IdP is a fixed,
      # server-derived constant rendered for copy — it is NOT a form field the
      # operator can set (an attacker-controlled redirect URI is the classic OIDC
      # open-redirect hole, so it's never operator-supplied).
      assert html =~ "/sign_in/sso/callback"
      refute has_element?(lv, "input[name='provider[redirect_uri]']")
      refute has_element?(lv, "input[name='provider[callback_url]']")
    end

    test "an edit leaving client_secret blank keeps the stored secret", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{client_secret: "stored-secret-value"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      # Submit the edit with a BLANK client_secret (the field is never
      # pre-filled). Whether blank means "keep the stored one" is the domain's
      # call, and it keeps it.
      lv
      |> form("#edit-provider-#{provider.id}", %{
        "provider_id" => provider.id,
        "provider" => %{
          "name" => "Renamed",
          "issuer" => "https://idp.test",
          "client_id" => "cid",
          "client_secret" => ""
        }
      })
      |> render_submit()

      reloaded = Repo.reload!(provider)
      assert reloaded.name == "Renamed"
      assert reloaded.client_secret == "stored-secret-value"
    end

    test "a rejected edit re-renders the error with no secret in the page", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{client_secret: "stored-secret-value"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      html =
        lv
        |> form("#edit-provider-#{provider.id}", %{
          "provider_id" => provider.id,
          "provider" => %{
            "name" => "Renamed",
            "issuer" => "http://idp.test",
            "client_id" => "cid",
            "client_secret" => "typed-replacement"
          }
        })
        |> render_submit()

      # The write's own changeset comes back (so the database's verdict survives),
      # and the domain has stripped both secrets out of it first.
      assert html =~ "must be an https URL"
      refute html =~ "stored-secret-value"
      refute html =~ "typed-replacement"
    end

    test "an edit can't repoint a fixed-issuer connection", %{conn: conn, account: account} do
      google =
        insert_provider(account, %{
          name: "Acme Google",
          kind: :google_workspace,
          issuer: "https://accounts.google.com"
        })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{google.id}/edit")

      # The rendered issuer is locked to the constant (LiveViewTest won't even let
      # a form set another value), so a different one can only arrive as a
      # crafted event — which is what this pushes.
      render_submit(lv, "update", %{
        "provider_id" => google.id,
        "provider" => %{
          "name" => "Renamed",
          "issuer" => "https://evil.test",
          "client_id" => "cid"
        }
      })

      # Google's issuer is a constant: posting around the lock changes nothing.
      reloaded = Repo.reload!(google)
      assert reloaded.name == "Renamed"
      assert reloaded.issuer == "https://accounts.google.com"
    end

    test "an invalid issuer renders inline on the field, not in a flash", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

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

    test "creating with the minimum fields applies the safe defaults", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      lv
      |> form("#provider_form", %{
        "provider" => %{
          "kind" => "okta",
          "name" => "Defaults Okta",
          "issuer" => "https://defaults.okta.com",
          "client_id" => "cid"
        }
      })
      |> render_submit()

      provider =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.ordered_by_name()
        |> Repo.all()
        |> Enum.find(&(&1.name == "Defaults Okta"))

      assert provider
      assert_redirect(lv, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The schema's documented defaults: stable identifier is `sub`, the provider
      # does NOT satisfy the account MFA gate — trusting someone else's second
      # factor is a deliberate claim, and defaulting it on let a password-only
      # OIDC server bypass the requirement — and it's created DISABLED so it
      # can't be signed in through until the admin explicitly turns it on.
      assert provider.identifier_claim == :sub
      assert provider.satisfies_mfa == false
      assert provider.enabled == false
      assert provider.provisioner == :jit
      assert provider.default_runner_access_mode == :none
    end

    test "a crafted create event is refused when the plan is downgraded mid-form", %{
      conn: conn,
      account: account
    } do
      # Mount on Enterprise, then drop the account to the free tier — exactly
      # the mid-form downgrade the row describes. The handler's predicate
      # re-checks the live plan (`Permissions.gated` takes a fresh context
      # call, like every gated handler), so the event is refused at the gate;
      # the context re-checks anyway and would refuse the same way.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      refute Emisar.Billing.sso_available?(account)

      html =
        lv
        |> form("#provider_form", %{
          "provider" => %{
            "kind" => "okta",
            "name" => "Downgraded Okta",
            "issuer" => "https://downgraded.okta.com",
            "client_id" => "cid"
          }
        })
        |> render_submit()

      assert html =~ "You don&#39;t have permission to do that."

      refute IdentityProvider.Query.not_deleted()
             |> Repo.all()
             |> Enum.any?(&(&1.name == "Downgraded Okta"))
    end

    test "a crafted create event is refused for a non-admin viewer", %{
      conn: conn,
      account: account,
      user: user
    } do
      # The viewer never sees the form (locked upsell), but the create handler is
      # gated server-side — a forged event is a no-op.
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      _ =
        render_submit(lv, "create", %{
          "provider" => %{
            "kind" => "okta",
            "name" => "Forged Okta",
            "issuer" => "https://forged.okta.com",
            "client_id" => "cid"
          }
        })

      refute IdentityProvider.Query.not_deleted()
             |> Repo.all()
             |> Enum.any?(&(&1.name == "Forged Okta"))
    end

    test "a crafted update event is refused for a non-admin viewer", %{
      conn: conn,
      account: account,
      user: user
    } do
      provider = insert_provider(account, %{name: "Untouchable"})
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      _ =
        render_submit(lv, "update", %{
          "provider_id" => provider.id,
          "provider" => %{
            "kind" => "okta",
            "name" => "Renamed By Viewer",
            "issuer" => "https://idp.test",
            "client_id" => "cid"
          }
        })

      assert Repo.reload!(provider).name == "Untouchable"
    end

    test "delete's typed-confirm: Confirm won't fire until the connection name matches", %{
      conn: conn,
      account: account
    } do
      # The delete dialog requires the operator to type the connection's exact
      # name before Confirm activates — pure UX friction in front of the
      # server-gated `delete`. A blank or wrong name keeps Confirm disabled, so
      # the `delete` event is never dispatched and the provider survives.
      provider = insert_provider(account, %{name: "Acme Okta"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      dialog = "delete-provider-#{provider.id}"

      assert has_element?(
               lv,
               "##{dialog}-confirm[phx-disable-with='Deleting…']"
             )

      # Empty token → Confirm disabled.
      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, dialog, "Delete connection")
      end

      # Wrong name → still disabled.
      type_confirm_token(lv, dialog, "Wrong Name")

      assert_raise ArgumentError, ~r/disabled/, fn ->
        confirm_dialog(lv, dialog, "Delete connection")
      end

      # The connection is untouched — no bypassing `delete` fired.
      refute Repo.reload!(provider).deleted_at
    end
  end

  describe "the connection detail page" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "every SSO view reads one crumb chain rooted at Team", %{conn: conn, account: account} do
      provider = insert_provider(account, %{name: "Acme Okta"})

      {:ok, _lv, add} = live(conn, ~p"/app/#{account}/settings/sso/new")
      {:ok, _lv, detail} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      {:ok, _lv, edit} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      # SSO has no nav item of its own, so every view starts at Team — /new used
      # to start at "Single sign-on" and read as a different feature.
      for html <- [add, detail, edit] do
        assert html =~ "Team"
        assert html =~ "Single sign-on"
      end

      assert add =~ "Add connection"
      refute add =~ "Add an identity provider"
      assert detail =~ "Acme Okta"
      assert edit =~ "Edit connection"

      # The middle crumb points at Team's anchored card. /settings/sso is a pure
      # redirect to that anchor, so linking it made the crumb bounce.
      team_card = ~p"/app/#{account}/settings/team" <> "#single-sign-on"
      assert add =~ team_card
      refute add =~ ~s(href="#{~p"/app/#{account}/settings/sso"}")
      refute detail =~ ~s(href="#{~p"/app/#{account}/settings/sso"}")
    end

    test "each section's note sits in that section's row, with no repeated title", %{
      conn: conn,
      user: user,
      account: account
    } do
      # `scim_enabled` is not castable on create — SSO.enable_scim/2 mints the
      # token and flips it, so a provider built straight from the changeset is
      # sign-in only whatever attrs say.
      off = insert_provider(account, %{name: "Sign-in only"})
      {:ok, off_lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{off.id}")

      # Sign-in only: member guidance stays visible without directory-specific notes.
      refute html =~ "Edit access adds"
      refute html =~ "Groups received from your identity provider"
      assert html =~ "Members linked to this connection"

      assert has_element?(
               off_lv,
               "#synced-members-#{off.id}-help",
               "To remove a member, use the Team page."
             )

      refute has_element?(
               off_lv,
               "#synced-members-#{off.id}-help",
               "deactivate them in your identity provider"
             )

      owner = Fixtures.Subjects.subject_for(user, account)

      on =
        insert_provider(account, %{name: "Synced", kind: :entra, default_role: :billing_manager})

      {:ok, on, _raw} = SSO.enable_scim(on, owner)
      {:ok, lv, synced} = live(conn, ~p"/app/#{account}/settings/sso/#{on.id}")

      for note <- [
            "Members and groups stay in sync",
            "Members get the highest role from their mapped groups",
            "Edit access adds",
            "Suspend access here for a temporary hold"
          ] do
        assert synced =~ note
      end

      assert synced =~ "remove their emisar access"
      refute synced =~ "remove their Emisar access"

      assert has_element?(
               lv,
               "#group-access-section-#{on.id}-help #connection-default-role-note",
               "Billing manager"
             )

      refute has_element?(lv, "#connection-role-summary")
      assert has_element?(lv, "#connection-default-access-note", "By default, groups use")
      refute has_element?(lv, "#connection-access-summary")
      refute has_element?(lv, "#connection-default-access-note", "All packs")

      assert has_element?(
               lv,
               "#synced-members-#{on.id}-help",
               "Members linked to this connection"
             )

      assert has_element?(
               lv,
               "#synced-members-#{on.id}-help",
               "To remove a member, deactivate them in your identity provider."
             )

      refute has_element?(lv, "#synced-members-#{on.id}-help", "use the Team page")

      for {section_id, note} <- [
            {"directory-sync-#{on.id}", "Members and groups stay in sync"},
            {"group-access-section-#{on.id}",
             "Members get the highest role from their mapped groups"},
            {"group-access-section-#{on.id}", "Edit access adds"},
            {"synced-members-#{on.id}", "Suspend access here for a temporary hold"}
          ] do
        assert has_element?(lv, "##{section_id} > div:first-child")
        assert has_element?(lv, "##{section_id} > div:nth-child(2)")
        assert has_element?(lv, "##{section_id} > aside##{section_id}-help", note)
      end

      # Actions stay in the primary header cell; the help rail begins only on
      # the content row below it.
      assert has_element?(
               lv,
               "#group-access-section-#{on.id} > div:first-child button",
               "Add mapping"
             )

      # The note carries no heading of its own: the section title is directly to
      # its left, and repeating it is what made the old single rail read as a
      # stack of headings.
      refute synced =~ "Synced groups &amp; users</"
      refute synced =~ "How this connection works"
    end

    test "renders just the one connection, with its config controls", %{
      conn: conn,
      account: account
    } do
      shown = insert_provider(account, %{name: "Acme Okta"})
      _other = insert_provider(account, %{name: "Globex Google", kind: :google_workspace})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{shown.id}")

      assert html =~ "Acme Okta"
      assert has_element?(lv, "#connection-status", "Sign-in status")
      assert has_element?(lv, "#connection-enabled-status", "Enabled")
      assert has_element?(lv, "#connection-status #sign-in-verification")
      assert has_element?(lv, "#connection-settings dt", "Provider")
      assert has_element?(lv, "#connection-summary > #connection-status")
      assert has_element?(lv, "#connection-summary > #connection-settings", "Sign-in settings")
      assert has_element?(lv, "#connection-provisioning h2", "User provisioning & directory sync")
      refute has_element?(lv, "#group-access-section-#{shown.id}")
      refute has_element?(lv, "#runner-access-mapping-section-#{shown.id}")
      assert has_element?(lv, "#connection-summary > #connection-docs", "Setting up")
      refute has_element?(lv, "#connection-summary > dl")
      refute has_element?(lv, "#connection-status dt")
      refute has_element?(lv, "#connection-member-access")
      refute has_element?(lv, "#connection-access-summary")
      refute has_element?(lv, "#connection-settings dt", "Allowed email domain")
      assert lv |> element("#connection-status") |> render() =~ "xl:col-start-1"
      assert lv |> element("#connection-settings") |> render() =~ "xl:row-start-2"
      assert lv |> element("#connection-docs") |> render() =~ "xl:row-start-2"
      assert has_element?(lv, "header #view-provider-activity-#{shown.id}", "View activity")
      assert has_element?(lv, "header #edit-provider-#{shown.id}", "Edit")
      refute has_element?(lv, "#connection-summary #view-provider-activity-#{shown.id}")
      refute has_element?(lv, "#connection-summary #edit-provider-#{shown.id}")
      # The per-connection delete dialog is detail-only (never on the overview list).
      assert has_element?(lv, "#delete-provider-#{shown.id}")
      # Delete lives in a bottom danger zone that opens the typed dialog — not a
      # ghost button beside Edit up top.
      assert html =~ "Delete this connection"
      assert has_element?(lv, "#connection-danger-zone")
      assert has_element?(lv, "#connection-danger-zone[class~='xl:col-start-1']")
      refute has_element?(lv, "#connection-danger-zone[class~='max-w-3xl']")
      refute has_element?(lv, "#connection-danger-zone[class~='xl:col-span-2']")
      # A single-connection view — the other connection isn't on this page.
      refute html =~ "Globex Google"
    end

    test "keeps sign-in and provisioning settings separate without an empty group section", %{
      conn: conn,
      account: account
    } do
      provider =
        insert_provider(account, %{
          allowed_email_domain: "example.com",
          satisfies_mfa: true,
          provisioner: :manual,
          default_role: :operator,
          default_runner_access_mode: :all,
          default_pack_access_mode: :all
        })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for label <- [
            "Provider",
            "Issuer",
            "Identifier claim",
            "Allowed email domain",
            "Multi-factor authentication"
          ] do
        assert has_element?(lv, "#connection-settings dt", label)
        refute has_element?(lv, "#connection-provisioning dt", label)
        refute has_element?(lv, "#group-access-section-#{provider.id} dt", label)
      end

      assert has_element?(lv, "#connection-provisioning dt", "New members")
      refute has_element?(lv, "#connection-settings dt", "New members")

      assert has_element?(lv, "#connection-settings dd", "@example.com")
      assert has_element?(lv, "#connection-settings dd", "Satisfied by this provider")
      assert has_element?(lv, "#connection-provisioning dd", "Require approval")
      refute has_element?(lv, "#group-access-section-#{provider.id}")

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} #connection-provisioning-summary dt + dd",
               "Require approval"
             )

      assert has_element?(lv, "#scim-status-#{provider.id} p", "SCIM")
      assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Disabled")
      refute has_element?(lv, "#connection-provisioning-policy")

      for summary <- ["connection-role-summary", "connection-access-summary"] do
        refute has_element?(lv, "##{summary}")
      end

      for label <- ["Default role", "Default runner access", "Default pack access"] do
        refute has_element?(lv, "#connection-provisioning dt", label)
      end
    end

    test "access mapping help explains additive grants without repeating defaults above groups",
         %{
           conn: conn,
           account: account,
           user: user
         } do
      provider =
        insert_provider(account, %{
          kind: :entra,
          default_runner_access_mode: :all,
          default_pack_access_mode: :all
        })

      owner = Fixtures.Subjects.subject_for(user, account)
      {:ok, provider, _token} = SSO.enable_scim(provider, owner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#connection-default-access-note", "By default, groups use")
      refute has_element?(lv, "#connection-access-summary")
      refute has_element?(lv, "#connection-role-summary")
      refute has_element?(lv, "#connection-default-access-note", "no runner access")

      assert has_element?(
               lv,
               "#group-access-section-#{provider.id}-help",
               "Reset to defaults removes that grant."
             )
    end

    test "groups SCIM and directory lists under provisioning before one Groups & access section",
         %{
           conn: conn,
           account: account,
           user: user
         } do
      owner = Fixtures.Subjects.subject_for(user, account)
      provider = insert_provider(account, %{kind: :entra})
      {:ok, provider, _token} = SSO.enable_scim(provider, owner)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(
               lv,
               "#connection-provisioning > #directory-sync-#{provider.id} h2",
               "User provisioning & directory sync"
             )

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} #connection-provisioning-summary dt",
               "New members"
             )

      refute has_element?(lv, "#connection-provisioning h3", "Directory sync")

      for {section, title} <- [
            {"synced-members", "Members"}
          ] do
        assert has_element?(lv, "#connection-provisioning > ##{section}-#{provider.id} h3", title)
        refute has_element?(lv, "##{section}-#{provider.id} > h2")
      end

      assert has_element?(
               lv,
               "#connection-provisioning + #group-access-section-#{provider.id} + #connection-danger-zone"
             )

      refute has_element?(lv, "#connection-role-summary")
      refute has_element?(lv, "#connection-access-summary")
      assert has_element?(lv, "#group-access-section-#{provider.id} button", "Add mapping")
    end

    test "separates issuer discovery from a real sign-in verification", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Saved but disabled", enabled: false})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#sign-in-verification", "Sign-in not verified")
      assert has_element?(lv, "#connection-status #connection-enabled-status", "Disabled")
      assert has_element?(lv, "#connection-status #verify-provider-sign-in-#{provider.id}")
      assert html =~ "Verify sign-in before enabling this connection."

      assert has_element?(
               lv,
               "#verify-provider-sign-in-#{provider.id}",
               "Verify sign-in"
             )

      assert has_element?(
               lv,
               "#verify-provider-sign-in-#{provider.id}[phx-hook='PendingButton'][phx-disable-with='Verifying…']"
             )

      assert Repo.reload!(provider).enabled == false
    end

    test "keeps a wrong admin proof inline and arms only a valid verification handoff", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Workforce Okta", enabled: false})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      lv |> element("#verify-provider-sign-in-#{provider.id}") |> render_click()
      assert_received {:email, email}
      assert has_element?(lv, "#provider-oidc-step-form")

      wrong =
        render_hook(lv, "confirm_oidc_step_up", %{
          "oidc_step" => %{"code" => "000000"}
        })

      assert wrong =~ "incorrect or expired"
      refute wrong =~ ~s(name="handoff")

      confirmed =
        render_hook(lv, "confirm_oidc_step_up", %{
          "oidc_step" => %{"code" => Fixtures.Auth.code_from_email(email)}
        })

      assert confirmed =~ "phx-trigger-action"
      assert confirmed =~ ~s(action="/app/#{account.slug}/settings/sso/identity/link")
      assert confirmed =~ ~s(name="handoff")
      assert Repo.reload!(provider).enabled == false
    end

    test "resends visibly and closes the verification dialog through server state", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Workforce Okta", enabled: false})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      lv |> element("#verify-provider-sign-in-#{provider.id}") |> render_click()
      assert_received {:email, _email}

      html = render(lv)
      assert html =~ ~s(id="provider-oidc-step-close")
      assert html =~ ~s(id="provider-oidc-step-resend")
      assert html =~ "hover:bg-zinc-800"
      assert has_element?(lv, "#provider-oidc-step-form button", "Cancel")

      assert has_element?(
               lv,
               "#provider-oidc-step-continue[class~='min-w-28'][phx-hook='PendingButton'][phx-disable-with='Confirming...']"
             )

      assert has_element?(
               lv,
               "#provider-oidc-step-resend[phx-hook='PendingButton'][phx-disable-with='Sending…']"
             )

      lv |> element("#provider-oidc-step-resend") |> render_click()
      assert_received {:email, _replacement_email}
      assert_push_event(lv, "code:reset", %{id: "provider-oidc-step-code"})
      assert render(lv) =~ "We sent a new code"

      lv |> element("#provider-oidc-step-close") |> render_click()
      refute has_element?(lv, "#provider-oidc-step-form")
    end

    test "a crafted step-up event with no verification in progress spends no attempt", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{name: "Workforce Okta", enabled: false})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      confirmed = render_hook(lv, "confirm_oidc_step_up", %{"oidc_step" => %{"code" => "000000"}})

      assert confirmed =~ "Start sign-in verification first."
      assert render_hook(lv, "resend_oidc_step_up", %{}) =~ "Start sign-in verification again."
      refute_received {:email, _email}
    end

    test "offers activation only after current settings have a real sign-in receipt", %{
      conn: conn,
      account: account,
      user: user
    } do
      unverified = insert_provider(account, %{name: "Needs verification", enabled: false})
      {:ok, unverified_lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{unverified.id}")

      refute has_element?(unverified_lv, "#enable-verified-provider-#{unverified.id}")

      denied =
        render_click(unverified_lv, "enable_verified_provider", %{
          "provider_id" => unverified.id
        })

      assert denied =~ "Verify a real sign-in"
      refute Repo.reload!(unverified).enabled

      verified =
        insert_provider(account, %{name: "Ready to enable", kind: :keycloak, enabled: false})
        |> mark_sign_in_verified(user)

      {:ok, verified_lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{verified.id}")

      assert html =~ "A real provider sign-in passed"

      assert has_element?(verified_lv, "#enable-verified-provider-#{verified.id}")
      assert has_element?(verified_lv, "button", "Enable for members")

      assert has_element?(
               verified_lv,
               "#enable-verified-provider-#{verified.id}-confirm[phx-disable-with='Enabling…']"
             )

      enabled =
        render_click(verified_lv, "enable_verified_provider", %{
          "provider_id" => verified.id
        })

      assert enabled =~ "Connection enabled for members."
      assert Repo.reload!(verified).enabled
    end

    test "a connection from another account reads as not found — back to the overview", %{
      conn: conn,
      account: account
    } do
      other_account = Fixtures.Accounts.create_account(%{plan: "enterprise"})
      foreign = insert_provider(other_account, %{name: "Other Co Okta"})

      dest = ~p"/app/#{account}/settings/team"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/settings/sso/#{foreign.id}")
    end

    test "an unknown connection id reads as not found — back to the overview", %{
      conn: conn,
      account: account
    } do
      dest = ~p"/app/#{account}/settings/team"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/settings/sso/#{Ecto.UUID.generate()}")
    end

    test "a non-admin viewer is denied the detail page and sees the upsell", %{
      conn: conn,
      account: account,
      user: user
    } do
      provider = insert_provider(account, %{name: "Acme Okta"})
      _ = make_viewer(user)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Single sign-on settings are restricted"
      refute html =~ "Acme Okta"
    end

    test "a non-admin forged verification event cannot issue a code", %{
      conn: conn,
      account: account,
      user: user
    } do
      provider = insert_provider(account, %{name: "Acme Okta"})
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      html =
        render_click(lv, "start_provider_sign_in_verification", %{
          "provider_id" => provider.id
        })

      refute html =~ "provider-oidc-step-form"
      refute_received {:email, _email}
    end
  end

  describe "the setup test-connection capstone" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "an SSRF issuer is blocked through the UI, before any discovery", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # Type a loopback/private issuer, then run the capstone — the context's SSRF
      # guard short-circuits before a fetch and the result banner says why.
      lv
      |> form("#provider_form", %{
        "provider" => %{"kind" => "okta", "issuer" => "https://10.0.0.5"}
      })
      |> render_change()

      html = render_click(lv, "test_connection", %{})

      assert html =~ "private, loopback, or metadata"
    end

    test "test_connection off the create form does not crash the socket", %{
      conn: conn,
      account: account
    } do
      # The :edit route loads :edit_form, not the :new/:show :form that
      # test_connection reads — and the event is reachable over the socket from any
      # route. It used to KeyError; the mount default + nil-guard make it a no-op.
      provider = insert_provider(account, %{})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      assert render_hook(lv, "test_connection", %{})
    end

    test "a non-https issuer prompts for a valid URL instead of fetching", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      lv
      |> form("#provider_form", %{
        "provider" => %{"kind" => "okta", "issuer" => "http://idp.test"}
      })
      |> render_change()

      html = render_click(lv, "test_connection", %{})

      assert html =~ "HTTPS URL first"
    end

    test "a capped account gets fixed retry copy without another discovery", %{
      conn: conn,
      account: account
    } do
      Emisar.Config.put_override(:emisar, :rate_limit_enabled, true)

      for _attempt <- 1..20 do
        assert Emisar.Throttle.check("sso_oidc_account_work", account.id, 20, 60_000) == :ok
      end

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      lv
      |> form("#provider_form", %{
        "provider" => %{"kind" => "okta", "issuer" => "https://idp.test"}
      })
      |> render_change()

      html = render_click(lv, "test_connection", %{})
      assert html =~ "Too many connection tests. Wait a minute and try again."
    end

    test "a non-admin viewer's forged test event is a gated no-op", %{
      conn: conn,
      account: account,
      user: user
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # The viewer never sees the form; a pushed test event is gated server-side —
      # no discovery, no result banner, no crash.
      html = render_click(lv, "test_connection", %{})

      refute html =~ "Discovery succeeded"
      refute html =~ "private, loopback, or metadata"
    end
  end

  describe "role mapping forms gating" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, account: account}
    end

    test "a connection without directory sync shows no group→role mapping form", %{
      conn: conn,
      account: account
    } do
      # Without SCIM there are no group controls or rows to show.
      provider = insert_provider(account, %{name: "No SCIM Okta"})
      refute Repo.reload!(provider).scim_enabled
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The connection itself renders…
      assert html =~ "No SCIM Okta"
      # …without an empty group section or directory mapping affordances.
      refute has_element?(lv, "#group-access-section-#{provider.id}")
      refute has_element?(lv, "#group-access-section-#{provider.id} button", "Add mapping")
      refute has_element?(lv, "#group-access-section-#{provider.id}-help")
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      refute has_element?(lv, "#create-runner-access-mapping-#{provider.id}")
      refute has_element?(lv, "#synced-groups-#{provider.id}")
      assert has_element?(lv, "#connection-provisioning > #synced-members-#{provider.id}")
      refute html =~ "No synced groups yet"
      refute html =~ "No access mappings yet"
    end
  end

  describe "provider setup guide" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "the identifier claim offers oid only for Entra", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      keycloak =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "keycloak"}})
        |> render_change()

      # Keycloak never issues `oid`; offering it invites a choice that fails at the
      # first sign-in with a missing-identifier error rather than at save time.
      refute keycloak =~ "oid — Microsoft Entra"
      assert keycloak =~ "sub — OIDC standard"

      entra =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "entra"}})
        |> render_change()

      assert entra =~ "oid — Microsoft Entra"
      # Entra must SELECT oid, not merely offer it: its `sub` is pairwise, so a
      # default of sub is a broken directory join the admin discovers much later.
      assert has_element?(
               lv,
               "select[name='provider[identifier_claim]'] option[value=oid][selected]"
             )

      # And `sub` is not on the list at all — a value the operator can pick that
      # cannot work is a trap, not a choice.
      refute entra =~ "sub — OIDC standard"

      # And the guide must point at Entra's own PAGE, not the generic section.
      assert entra =~ "/docs/integrations/entra"
    end

    test "a claim already stored on a connection stays on the list", %{
      conn: conn,
      account: account
    } do
      # Narrowing the list must not silently retype an existing connection: a
      # Keycloak provider saved with `oid` would come back as `sub` on the next
      # edit, breaking every returning member's identity match.
      provider =
        Fixtures.SSO.create_identity_provider(
          account_id: account.id,
          kind: :keycloak,
          identifier_claim: :oid
        )

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      assert html =~ "oid — stored on this connection"
    end

    test "only a named provider promises screenshots", %{conn: conn, account: account} do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # No kind picked yet: there is no provider guide to point at, so the link
      # names the docs page it does go to.
      assert html =~ "Single sign-on docs"
      refute html =~ "Step-by-step guide"

      picked =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "okta"}})
        |> render_change()

      # A picked provider links its own guide, named for what the page is.
      assert picked =~ "Step-by-step guide"
      assert picked =~ "/docs/integrations/okta"

      google =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "google_workspace"}})
        |> render_change()

      assert google =~ "Step-by-step guide"
      assert google =~ "/docs/integrations/google-workspace"
    end

    test "the guide names what each provider does about the directory", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # The steps above this line are the same shape everywhere — create an app,
      # register the redirect URI, paste the credentials. What actually differs,
      # and what the operator hits straight after, is the directory. The line has
      # to earn its place by saying that rather than announcing a guide exists.
      notes = %{
        "okta" => "Directory sync is a second Okta app",
        "entra" => "directory sync is a separate enterprise application",
        "jumpcloud" => "One JumpCloud application covers both",
        "keycloak" => "Directory sync requires a third-party Keycloak extension",
        "google_workspace" => "Google Workspace doesn&#39;t support directory sync with emisar"
      }

      for {kind, note} <- notes do
        html =
          lv
          |> form("#provider_form", %{"provider" => %{"kind" => kind}})
          |> render_change()

        assert html =~ note, "#{kind}: expected the directory note"
        # The rail is already titled "Setting up <provider>" — the line must not
        # spend itself repeating the name or saying a guide exists.
        refute html =~ "setup guide"
      end
    end
  end

  describe "current provider setup directions" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, account: account}
    end

    test "Google uses Auth Platform and an internal audience", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      html =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "google_workspace"}})
        |> render_change()

      assert html =~ "Google Auth Platform"
      assert html =~ "Clients → Create client"
      assert html =~ "Audience"
      assert html =~ "Internal"
      assert html =~ "Verify sign-in"
      assert html =~ "Enable for members"
      refute html =~ "APIs &amp; Services"
      refute html =~ "fields below"
    end

    test "Okta identifies the org URL, and Entra does not show a DPoP instruction", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      okta =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "okta"}})
        |> render_change()

      assert okta =~ "Copy your org URL from the account menu"
      assert okta =~ "DPoP-bound tokens"

      entra =
        lv
        |> form("#provider_form", %{"provider" => %{"kind" => "entra"}})
        |> render_change()

      refute entra =~ "DPoP"
    end
  end

  describe "directory sync (SCIM)" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{name: "Acme Okta"})
      %{conn: conn, user: user, account: account, provider: provider}
    end

    test "enable mints a token shown once + the SCIM base URL", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, sign_in_only} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      refute sign_in_only =~ "Members and groups stay in sync"
      assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Disabled")
      assert has_element?(lv, "#scim-actions-#{provider.id} #enable-scim-#{provider.id}")
      refute has_element?(lv, "#scim-request-status-#{provider.id}")
      refute has_element?(lv, "#scim-setup-#{provider.id}")
      refute has_element?(lv, "#scim-url-#{provider.id}")

      assert has_element?(
               lv,
               "#enable-scim-#{provider.id}[phx-hook='PendingButton'][phx-disable-with='Enabling…']"
             )

      html = render_click(lv, "enable_scim", %{"id" => provider.id})

      assert html =~ "Directory sync enabled."
      assert html =~ "shown only once"
      assert html =~ "/scim/v2"
      assert html =~ "Members and groups stay in sync"
      # The freshly-minted ems- token is rendered exactly once, in the reveal.
      assert html =~ "ems-"
      # The IdP-side SCIM setup steps appear once sync is on.
      assert has_element?(lv, "#scim-setup-#{provider.id}[open] summary", "Setup instructions")
      assert html =~ "externalId"

      sync_controls = lv |> element("#directory-sync-#{provider.id}") |> render()
      assert has_element?(lv, "#scim-actions-#{provider.id} #rotate-scim-#{provider.id}")
      assert has_element?(lv, "#scim-actions-#{provider.id} #disable-scim-#{provider.id}")
      assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Enabled")

      assert has_element?(
               lv,
               "#scim-request-status-#{provider.id}",
               "(waiting for first request)"
             )

      assert has_element?(
               lv,
               "#scim-setup-#{provider.id} > ol > li:nth-child(2) p",
               "Set the connector's SCIM endpoint to this base URL:"
             )

      assert has_element?(
               lv,
               "#scim-setup-#{provider.id} > ol > li:nth-child(2) #scim-endpoint-#{provider.id} #scim-url-#{provider.id}",
               "/scim/v2"
             )

      refute has_element?(lv, "#scim-setup-#{provider.id} > #scim-endpoint-#{provider.id}")
      refute has_element?(lv, "#scim-setup-#{provider.id}", "Base URL above")
      refute has_element?(lv, "#scim-setup-#{provider.id}", "value above")
      assert has_element?(lv, "#scim-url-#{provider.id} button[data-copy-text$='/scim/v2']")

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} > div:first-child + #scim-actions-#{provider.id}"
             )

      assert has_element?(lv, "#scim-status-#{provider.id}[class~='sm:justify-between']")

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} #scim-enabled-status-#{provider.id}",
               "Enabled"
             )

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} > div:first-child #connection-provisioning-summary",
               "Add on first sign-in"
             )

      assert has_element?(
               lv,
               "#scim-status-#{provider.id} p + #scim-enabled-status-#{provider.id}",
               "Enabled"
             )

      assert has_element?(
               lv,
               "#scim-enabled-status-#{provider.id} > span.text-brand-300",
               "Enabled"
             )

      assert has_element?(
               lv,
               "#scim-enabled-status-#{provider.id} > #scim-request-status-#{provider.id}.text-zinc-400",
               "(waiting for first request)"
             )

      refute has_element?(lv, "#scim-enabled-status-#{provider.id}.text-brand-300")
      refute has_element?(lv, "#scim-status-#{provider.id} dt", "Status")

      refute has_element?(
               lv,
               "#directory-sync-#{provider.id} header #scim-actions-#{provider.id}"
             )

      refute has_element?(
               lv,
               "#directory-sync-#{provider.id} header #scim-enabled-status-#{provider.id}"
             )

      refute has_element?(
               lv,
               "#directory-sync-#{provider.id} header #scim-request-status-#{provider.id}"
             )

      refute has_element?(lv, "#scim-status-#{provider.id} #scim-url-#{provider.id}")
      assert has_element?(lv, "#scim-endpoint-#{provider.id} + p", "bearer token")

      assert has_element?(
               lv,
               "#rotate-scim-#{provider.id}-confirm[phx-disable-with='Rotating…']"
             )

      assert has_element?(
               lv,
               "#disable-scim-#{provider.id}-confirm[phx-disable-with='Disabling…']"
             )

      assert sync_controls =~ "Rotate token"
      assert sync_controls =~ "Disable"
      assert sync_controls =~ "first-child]:mb-0"
      refute sync_controls =~ "Last connected"

      reloaded = Repo.reload!(provider)
      assert reloaded.scim_enabled
      assert reloaded.scim_token_prefix
    end

    test "a downgraded account can still disable existing directory sync", %{
      conn: conn,
      account: account,
      provider: provider,
      user: user
    } do
      owner = Fixtures.Subjects.subject_for(user, account)
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)

      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      refute Emisar.Billing.sso_available?(account)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "This connection is dormant"
      assert html =~ "Sign-ins and its directory token are refused"
      assert html =~ "Disable directory sync"
      refute html =~ "Turn off directory sync"
      assert has_element?(lv, "#disable-scim-#{provider.id}")

      assert has_element?(
               lv,
               "#disable-scim-#{provider.id}-confirm[phx-disable-with='Disabling…']"
             )

      disabled = render_click(lv, "disable_scim", %{"id" => provider.id})
      assert disabled =~ "Directory sync disabled."
      refute Repo.reload!(provider).scim_enabled
    end

    test "the token is never rendered back after dismissal / reload", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      shown = render_click(lv, "enable_scim", %{"id" => provider.id})
      [_, token | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, shown) || [nil, nil]
      assert is_binary(token)

      # Dismiss the reveal — the raw token must be gone from the DOM.
      dismissed = render_click(lv, "dismiss_scim_token", %{})
      refute dismissed =~ token

      assert has_element?(
               lv,
               "#scim-setup-#{provider.id}:not([open]) summary",
               "Setup instructions"
             )

      # And a fresh mount never re-renders it (write-only, like client_secret).
      {:ok, lv2, remounted} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      refute remounted =~ token
      # Directory sync still shows as on, just without the secret.
      assert has_element?(lv2, "#scim-enabled-status-#{provider.id}", "Enabled")
    end

    test "rotate issues a new token; disable turns sync off", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      first = render_click(lv, "enable_scim", %{"id" => provider.id})
      [_, token1 | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, first)

      render_click(lv, "dismiss_scim_token", %{})
      refute has_element?(lv, "#scim-setup-#{provider.id}[open]")

      rotated = render_click(lv, "rotate_scim", %{"id" => provider.id})
      assert rotated =~ "SCIM token rotated."
      [_, token2 | _] = Regex.run(~r/(ems-[A-Za-z0-9_-]{20,})/, rotated)
      refute token1 == token2
      assert has_element?(lv, "#scim-setup-#{provider.id}[open]")
      assert {:ok, _provider} = SSO.authenticate_scim_token(token2)

      disabled = render_click(lv, "disable_scim", %{"id" => provider.id})
      assert disabled =~ "Directory sync disabled."
      refute disabled =~ token2
      refute Repo.reload!(provider).scim_enabled
      assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Disabled")
      assert has_element?(lv, "#scim-actions-#{provider.id} #enable-scim-#{provider.id}")
      refute has_element?(lv, "#scim-request-status-#{provider.id}")
      refute has_element?(lv, "#scim-setup-#{provider.id}")
      refute has_element?(lv, "#rotate-scim-#{provider.id}")
      refute has_element?(lv, "#disable-scim-#{provider.id}")
      assert has_element?(lv, "#connection-provisioning > #synced-members-#{provider.id}")
      refute has_element?(lv, "#group-access-section-#{provider.id}")
      refute has_element?(lv, "#group-access-section-#{provider.id} button", "Add mapping")
      refute has_element?(lv, "#synced-groups-#{provider.id}")
    end

    test "a non-admin viewer cannot enable directory sync", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly.
      _ = render_click(lv, "enable_scim", %{"id" => provider.id})
      refute Repo.reload!(provider).scim_enabled
    end

    test "a non-admin viewer cannot rotate or disable a SCIM token (forged events)", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider
    } do
      # SCIM is enabled by an admin first, then the role is dropped to viewer —
      # the rotate/disable handlers are Permissions.gated AND the context re-checks
      # `manage_sso` + Enterprise, so a forged event leaves the token untouched.
      owner = Fixtures.Subjects.subject_for(user, account)
      {:ok, enabled, _raw} = SSO.enable_scim(provider, owner)
      prefix = enabled.scim_token_prefix

      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      _ = render_click(lv, "rotate_scim", %{"id" => provider.id})
      _ = render_click(lv, "disable_scim", %{"id" => provider.id})

      # Still enabled, and the prefix is the admin-minted one (no rotation landed).
      reloaded = Repo.reload!(provider)
      assert reloaded.scim_enabled
      assert reloaded.scim_token_prefix == prefix
    end

    test "Google Workspace hides the enable panel and says why", %{conn: conn, account: account} do
      google =
        insert_provider(account, %{
          name: "Acme Google",
          kind: :google_workspace,
          provisioner: :manual
        })

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{google.id}")

      assert html =~ "isn&#39;t available for Google Workspace"
      assert has_element?(lv, "#connection-provisioning dd", "Require approval")
      refute html =~ "Members are added when they first"
      refute has_element?(lv, "#connection-provisioning", "Enterprise plan")
      assert has_element?(lv, "#connection-provisioning > #synced-members-#{google.id}")
      refute has_element?(lv, "#group-access-section-#{google.id}")
      refute has_element?(lv, "#group-access-section-#{google.id} button", "Add mapping")
      refute html =~ "enable_scim"
    end

    test "a crafted enable on Google Workspace is refused, not merely hidden", %{
      conn: conn,
      account: account
    } do
      google = insert_provider(account, %{name: "Acme Google", kind: :google_workspace})

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{google.id}")

      # The panel is hidden, so the event has to come from a crafted push — the
      # domain is what refuses it, and the page says why.
      shown = render_click(lv, "enable_scim", %{"id" => google.id})

      assert shown =~ "can&#39;t push a directory to emisar"
      refute Repo.reload!(google).scim_enabled
      assert is_nil(Repo.reload!(google).scim_token_prefix)
    end

    test "Keycloak keeps the enable panel, and its setup hint names the plugin", %{
      conn: conn,
      account: account
    } do
      keycloak = insert_provider(account, %{name: "Acme Keycloak", kind: :keycloak})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{keycloak.id}")

      # Keycloak has no outbound SCIM of its own, but emisar's endpoint is generic
      # enough for a third-party extension to drive — so the surface stays.
      assert html =~ "enable_scim"
      refute html =~ "isn&#39;t available for Keycloak"

      shown = render_click(lv, "enable_scim", %{"id" => keycloak.id})
      assert shown =~ "ships no outbound provisioning of its own"
    end
  end

  describe "synced members" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})
      owner = Fixtures.Subjects.subject_for(user, account)
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)

      {:ok, %{identity: identity, membership: membership}} =
        SSO.scim_provision_user(provider, %{
          external_id: "kc|dana",
          email: "dana@northstar.example",
          full_name: "Dana Sync"
        })

      %{
        conn: conn,
        user: user,
        account: account,
        provider: provider,
        identity: identity,
        membership: membership
      }
    end

    test "your own row keeps its role and explains the disabled controls", %{
      conn: conn,
      user: user,
      account: account,
      provider: provider
    } do
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)

      Fixtures.SSO.create_user_identity(%{
        account_id: account.id,
        provider_id: provider.id,
        user_id: user.id,
        created_by: :user,
        provisioned_via: :oidc_link
      })

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#self-role-lock-#{membership.id}-tt", "Owner")
      assert has_element?(lv, "#self-role-lock-#{membership.id}-tt [data-icon='role.restricted']")
      refute has_element?(lv, "#self-role-lock-#{membership.id}-tt button")

      assert has_element?(
               lv,
               "#self-role-lock-#{membership.id}[role='tooltip']",
               "You can't change your own role."
             )

      assert has_element?(
               lv,
               "#self-suspend-lock-#{membership.id}-tt button[disabled]",
               "Suspend access"
             )

      assert has_element?(
               lv,
               "#self-suspend-lock-#{membership.id}[role='tooltip']",
               "You can't suspend your own access."
             )

      refute has_element?(lv, "#synced-role-#{membership.id}-admin")

      render_click(lv, "change_member_role", %{
        "membership_id" => membership.id,
        "role" => "admin"
      })

      render_click(lv, "suspend_member", %{"membership_id" => membership.id})
      assert Repo.reload!(membership).role == :owner
      refute Accounts.membership_disabled?(Repo.reload!(membership))
    end

    test "lists the provisioned member and suspends them from the connection page", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Members"
      assert html =~ "Dana Sync"
      refute Emisar.Accounts.Membership.disabled?(membership)

      assert has_element?(
               lv,
               "#suspend-scim-#{membership.id}-confirm[phx-disable-with='Suspending…']"
             )

      render_click(lv, "suspend_member", %{"membership_id" => membership.id})

      assert Emisar.Accounts.Membership.disabled?(Repo.reload!(membership))

      assert has_element?(
               lv,
               "#reactivate-scim-#{membership.id}[phx-hook='PendingButton'][phx-disable-with='Restoring…']"
             )

      render_click(lv, "reinstate_member", %{"membership_id" => membership.id})

      refute Emisar.Accounts.Membership.disabled?(Repo.reload!(membership))
    end

    test "an IdP-deactivated member keeps a disabled Reactivate action with its remedy", %{
      conn: conn,
      account: account,
      provider: provider,
      identity: identity,
      membership: membership
    } do
      {:ok, _} =
        SSO.scim_update_user(
          provider,
          identity.id,
          %SSO.SCIMUserUpdate{active: false}
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      trigger = "#reactivate-in-idp-#{membership.id}-tt"

      assert has_element?(lv, "#{trigger} button[disabled]", "Restore access")

      assert has_element?(
               lv,
               "#{trigger} [role='tooltip']",
               "Reactivate them there"
             )

      refute has_element?(lv, "#{trigger} button[phx-click]")
    end

    test "a large directory renders one page with a pager, not the whole roster", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      # Directory sync is precisely what makes this list long, and the page used
      # to hold EVERY identity — each with a preloaded user and membership — in
      # one socket's assigns, re-diffed on every update.
      for n <- 1..20 do
        {:ok, _provisioned} =
          SSO.scim_provision_user(provider, %{
            external_id: "kc|bulk-#{n}",
            email: "bulk-#{n}@northstar.example",
            full_name: "Bulk Person #{n}"
          })
      end

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The header count is the whole roster; the pager says how much of it is here.
      assert has_element?(lv, "#synced-members-#{provider.id}-pager", "20 / 21 total")
      assert html =~ "Bulk Person 20"
      refute html =~ "Dana Sync"

      html =
        lv
        |> element("#synced-members-#{provider.id}-pager a", "Next →")
        |> render_click()

      assert html =~ "Dana Sync"
      refute html =~ "Bulk Person 20"
      refute html =~ "No members yet"
    end

    test "a connection with no members shows its sign-in empty state", %{
      conn: conn,
      account: account
    } do
      unsynced = insert_provider(account, %{name: "Unsynced Entra", kind: :entra})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{unsynced.id}")

      assert html =~ "No members yet"
      assert html =~ "Members appear here after signing in through this connection."
      refute html =~ "or being added by directory sync"
      refute html =~ "Couldn&#39;t load members"
    end

    test "a failed membership read asks for a retry instead of claiming nobody is there", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Drop only the membership-read permission: the provider and synced-identity
      # reads (manage_sso) still succeed, so this fails exactly the roster read.
      :sys.replace_state(lv.pid, fn state ->
        update_in(
          state.socket.assigns.current_subject.permissions,
          &MapSet.delete(&1, Emisar.Accounts.Authorizer.view_own_account_permission())
        )
      end)

      html = render_patch(lv, ~p"/app/#{account}/settings/sso/#{provider.id}?reload=1")

      assert html =~ "Couldn&#39;t load members"

      assert html =~
               "Refresh the page to try again."

      refute html =~ "No members yet"
      refute html =~ "Dana Sync"
    end

    test "a downgraded account's role lock points at the member's IdP groups", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {_deleted, _} =
        Emisar.Billing.Subscription.Query.all()
        |> Emisar.Billing.Subscription.Query.by_account_id(account.id)
        |> Repo.delete_all()

      Fixtures.Accounts.create_subscription(account, "team")

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~
               "Role is managed by directory sync — change this member&#39;s groups in your IdP"

      refute html =~ "set it in Groups & access"
      assert has_element?(lv, "#connection-provisioning", "Enterprise plan")

      assert has_element?(
               lv,
               "#connection-provisioning > #synced-members-#{provider.id}",
               "Dana Sync"
             )

      refute has_element?(lv, "#group-access-section-#{provider.id}")
      refute has_element?(lv, "#connection-provisioning #directory-sync-#{provider.id}")
      refute has_element?(lv, "#synced-groups-#{provider.id}")
      refute has_element?(lv, "#group-access-section-#{provider.id} button", "Add mapping")
    end

    test "a crafted suspend is refused for a non-admin viewer", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership,
      user: user
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      _ = render_click(lv, "suspend_member", %{"membership_id" => membership.id})

      refute Emisar.Accounts.Membership.disabled?(Repo.reload!(membership))
    end
  end

  describe "role mapping" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      owner = Fixtures.Subjects.subject_for(user, account)
      provider = insert_provider(account, %{name: "Acme Okta"})
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)
      %{conn: conn, user: user, account: account, provider: provider, owner: owner}
    end

    test "all directory lists have compact empty states without empty pagers", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for {section, title, pager} <- [
            {"group-access-section", "No synced groups yet", "group-access"},
            {"synced-members", "No members yet", "synced-members"}
          ] do
        assert has_element?(lv, "##{section}-#{provider.id} h2", title)
        refute has_element?(lv, "##{pager}-#{provider.id}-pager")
      end

      assert has_element?(
               lv,
               "#synced-members-#{provider.id}",
               "or being added by directory sync"
             )
    end

    test "opening a mapping composer replaces its empty state until canceled", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for {section, title, open_event, cancel_event, form_id} <- [
            {"group-access-section", "No synced groups yet", "add_mapping_form",
             "cancel_add_mapping", "create-mapping"}
          ] do
        assert has_element?(lv, "##{section}-#{provider.id} h2", title)
        render_click(lv, open_event, %{})
        assert has_element?(lv, "##{form_id}-#{provider.id}")
        refute has_element?(lv, "##{section}-#{provider.id} h2", title)

        render_click(lv, cancel_event, %{})
        refute has_element?(lv, "##{form_id}-#{provider.id}")
        assert has_element?(lv, "##{section}-#{provider.id} h2", title)
      end
    end

    test "failed directory reads show errors instead of empty results", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      :sys.replace_state(lv.pid, fn state ->
        socket =
          Phoenix.Component.assign(state.socket,
            group_mappings_load_error?: true
          )

        %{state | socket: socket}
      end)

      render_click(lv, "dismiss_scim_token", %{})

      for {section, title, empty_title} <- [
            {"group-access-section", "Couldn't load groups", "No synced groups yet"}
          ] do
        assert has_element?(lv, "##{section}-#{provider.id} h2", title)
        refute has_element?(lv, "##{section}-#{provider.id} h2", empty_title)
      end
    end

    test "a group's role menu creates its mapping without opening a form", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      assert {:ok, %{identity: identity}} =
               SSO.scim_provision_user(provider, %{
                 external_id: "triage-member",
                 email: "triage@example.com",
                 full_name: "Triage Member"
               })

      assert {:ok, group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: "triage",
                 display: "Triage",
                 member_ids: [identity.id]
               })

      mapped_group = sync_group(provider, "eng", "Engineering")

      {:ok, existing} =
        SSO.create_group_mapping(
          provider,
          %{directory_group_id: mapped_group.id, role: :admin},
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      refute has_element?(lv, "#synced-groups-#{provider.id}")
      assert has_element?(lv, "#synced-group-#{group.id}", "1 member")
      assert has_element?(lv, "#synced-group-#{mapped_group.id}", "0 members")
      assert has_element?(lv, "#group-role-#{mapped_group.id} > summary", "Admin")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Map role")
      refute has_element?(lv, "#group-role-#{group.id} [role='separator']")
      refute has_element?(lv, "#group-role-#{group.id} button", "Remove mapping")
      refute has_element?(lv, "#group-role-#{group.id} button[phx-value-role='owner']")
      refute has_element?(lv, "#create-mapping-#{provider.id}")

      lv |> element("#group-role-#{group.id} button[phx-value-role='operator']") |> render_click()
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")
      assert has_element?(lv, "#synced-group-#{group.id}", "1 member")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      mappings = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      mapping = Enum.find(mappings, &(&1.directory_group_id == group.id))
      assert mapping.role == :operator

      assert has_element?(lv, "#group-role-#{group.id} [role='separator']")

      assert has_element?(
               lv,
               "#group-role-#{group.id} #remove-role-mapping-#{mapping.id}[class~='text-rose-300']",
               "Remove mapping"
             )

      assert has_element?(
               lv,
               "#synced-group-#{group.id} > #delete-mapping-#{mapping.id}[role='dialog']"
             )

      refute has_element?(lv, "#group-role-#{group.id} [role='dialog']")

      refute has_element?(
               lv,
               "#role-mapping-#{mapping.id} > div > div > button",
               "Remove mapping"
             )

      lv |> element("#delete-mapping-#{mapping.id}-confirm") |> render_click()
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Map role")
      assert has_element?(lv, "#synced-group-#{group.id}", "1 member")
      assert has_element?(lv, "#role-mapping-#{existing.id}", "Admin")
    end

    test "role-menu errors stay at the group and clear after a successful change", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "roles", "Role choices")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for role <- [nil, %{}, ["admin"]] do
        render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => role})
      end

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => "owner"})

      assert has_element?(
               lv,
               "#group-role-error-#{group.id}[role='alert']",
               "directory sync cannot grant owner"
             )

      assert has_element?(lv, "#group-role-#{group.id} > summary", "Map role")
      refute has_element?(lv, "#create-mapping-#{provider.id}")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))

      render_click(lv, "add_mapping_form", %{})
      render_click(lv, "select_group", %{"scope" => "role", "group_id" => group.id})

      lv
      |> form("#create-mapping-#{provider.id}", %{"mapping" => %{"role" => "operator"}})
      |> render_submit()

      refute has_element?(lv, "#group-role-error-#{group.id}")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")

      render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => "owner"})

      assert has_element?(
               lv,
               "#group-role-error-#{group.id}",
               "directory sync cannot grant owner"
             )

      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")
      lv |> element("#group-role-#{group.id} button[phx-value-role='viewer']") |> render_click()
      refute has_element?(lv, "#group-role-error-#{group.id}")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Viewer")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert mapping.role == :viewer
    end

    test "a mapping created after render is not overwritten by a stale menu", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "concurrent", "Concurrent mapping")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      attrs = %{directory_group_id: group.id, role: :operator}
      {:ok, original} = SSO.create_group_mapping(provider, attrs, owner)

      lv |> element("#group-role-#{group.id} button[phx-value-role='admin']") |> render_click()

      assert has_element?(
               lv,
               "#group-role-error-#{group.id}",
               "This group already has a role mapping."
             )

      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert mapping.id == original.id
      assert mapping.role == :operator

      render_click(lv, "delete_mapping", %{"id" => mapping.id})
      refute has_element?(lv, "#group-role-error-#{group.id}")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Map role")
    end

    test "a retired group's saved mapping stays visible and removable", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "retired", "Retired group")
      attrs = %{directory_group_id: group.id, role: :operator}
      {:ok, mapping} = SSO.create_group_mapping(provider, attrs, owner)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      refute has_element?(lv, "#synced-group-#{group.id}", "No longer synced")

      assert {:ok, _} = SSO.scim_delete_group(provider, group.id)
      refresh_directory(lv)
      assert has_element?(lv, "#synced-group-#{group.id}", "No longer synced")
      assert has_element?(lv, "#role-mapping-#{mapping.id}", "Operator")
      assert has_element?(lv, "#delete-mapping-#{mapping.id}", "Remove mapping")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")
      assert has_element?(lv, "#group-role-#{group.id} #remove-role-mapping-#{mapping.id}")
      refute has_element?(lv, "#group-role-#{group.id} button[phx-value-role]")
      refute has_element?(lv, "#group-role-#{group.id} [role='separator']")

      :sys.replace_state(lv.pid, fn state ->
        groups = Enum.map(state.socket.assigns.access_groups, &%{&1 | mapping: nil})
        socket = Phoenix.Component.assign(state.socket, :access_groups, groups)
        %{state | socket: socket}
      end)

      render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => "admin"})
      refute has_element?(lv, "#group-role-#{group.id}")
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      refresh_directory(lv)

      render_click(lv, "delete_mapping", %{"id" => mapping.id})
      refute has_element?(lv, "#synced-group-#{group.id}")
      assert has_element?(lv, "#group-access-section-#{provider.id}", "No synced groups yet")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "row menus preserve an open Add mapping draft", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      first = sync_group(provider, "first", "First group")
      second = sync_group(provider, "second", "Second group")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "add_mapping_form", %{})
      render_click(lv, "select_group", %{"scope" => "role", "group_id" => first.id})

      lv
      |> form("#create-mapping-#{provider.id}", %{"mapping" => %{"role" => "admin"}})
      |> render_change()

      assert has_element?(lv, "#map-group-role-#{second.id}[disabled]")
      render_click(lv, "set_group_role", %{"group_id" => second.id, "role" => "viewer"})
      assert has_element?(lv, "#role-group-picker-#{provider.id} > summary", "First group")

      assert has_element?(
               lv,
               "#create-mapping-role-#{provider.id} option[value='admin'][selected]"
             )

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      render_click(lv, "cancel_add_mapping", %{})
      lv |> element("#group-role-#{second.id} button[phx-value-role='viewer']") |> render_click()
      assert has_element?(lv, "#group-role-#{second.id} > summary", "Viewer")
      assert has_element?(lv, "#group-role-#{first.id} > summary", "Map role")
      refute has_element?(lv, "#create-mapping-#{provider.id}")
    end

    test "role menus reject groups outside the current connection", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      other = insert_provider(account, %{kind: :entra}) |> Fixtures.SSO.enable_scim()
      other_group = sync_group(other, "other-connection", "Other connection")
      foreign_account = Fixtures.Accounts.create_account(%{plan: "enterprise"})
      foreign = insert_provider(foreign_account, %{}) |> Fixtures.SSO.enable_scim()
      foreign_group = sync_group(foreign, "foreign", "Foreign group")
      foreign_user = Fixtures.Users.create_user()
      foreign_subject = Fixtures.Subjects.subject_for(foreign_user, foreign_account)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for id <- [other_group.id, foreign_group.id, "not-a-group-id"] do
        render_click(lv, "set_group_role", %{"group_id" => id, "role" => "admin"})
        refute has_element?(lv, "#create-mapping-#{provider.id}")
      end

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(other, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(foreign, foreign_subject, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "creates, lists, and deletes a role mapping", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "00g-admins", "Admins")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The add form is behind the "Add mapping" button — hidden until clicked.
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      render_click(lv, "add_mapping_form", %{})
      assert has_element?(lv, "#create-mapping-#{provider.id}")

      assert has_element?(
               lv,
               "#create-mapping-#{provider.id}-submit[phx-hook='PendingButton'][phx-disable-with='Adding...']"
             )

      # The picker is server-searched: opening the form lists the first groups,
      # and the chosen one rides the form as a hidden id.
      assert has_element?(lv, "#create-mapping-#{provider.id} button", "Admins")
      render_click(lv, "select_group", %{"scope" => "role", "group_id" => group.id})

      html =
        lv
        |> form("#create-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "mapping" => %{"role" => "admin"}
        })
        |> render_submit()

      assert html =~ "Role mapping added."
      # The row renders with its display + role.
      assert html =~ "Admins"
      assert html =~ "00g-admins"

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))

      assert has_element?(
               lv,
               "#delete-mapping-#{mapping.id}-confirm[phx-disable-with='Removing…']"
             )

      # Remove only the mapping — the group remains and can be mapped again.
      deleted = render_click(lv, "delete_mapping", %{"id" => mapping.id})
      assert deleted =~ "Role mapping removed."

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert has_element?(lv, "#synced-group-#{group.id}", "Admins")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Map role")
      refute has_element?(lv, "#role-mapping-#{mapping.id}")
    end

    test "one group pager retains the row until both mappings and the directory group are gone",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner
         } do
      entries =
        for n <- 1..21 do
          suffix = n |> Integer.to_string() |> String.pad_leading(2, "0")
          group = sync_group(provider, "group-#{suffix}", "Group #{suffix}")

          {:ok, role} =
            SSO.create_group_mapping(
              provider,
              %{directory_group_id: group.id, role: :operator},
              owner
            )

          {:ok, access} =
            SSO.create_group_runner_access_mapping(
              provider,
              %{directory_group_id: group.id, runner_access_mode: :all},
              owner
            )

          {group, role, access}
        end

      {last_group, last_role, last_access} = List.last(entries)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      assert has_element?(lv, "#group-access-#{provider.id}-pager", "20 / 21 total")
      refute has_element?(lv, "#runner-access-mappings-#{provider.id}-pager")

      lv |> element("#group-access-#{provider.id}-pager a", "Next →") |> render_click()
      assert has_element?(lv, "#synced-group-#{last_group.id}", "Group 21")
      assert has_element?(lv, "#group-access-facts-#{last_group.id}", "All")

      render_click(lv, "delete_mapping", %{"id" => last_role.id})
      assert has_element?(lv, "#group-role-#{last_group.id} > summary", "Map role")
      assert has_element?(lv, "#group-access-#{provider.id}-pager", "1 / 21")

      assert {:ok, _} = SSO.scim_delete_group(provider, last_group.id)
      refresh_directory(lv)
      assert has_element?(lv, "#synced-group-#{last_group.id}", "No longer synced")
      refute has_element?(lv, "#synced-group-#{last_group.id} [phx-click='edit_group_access']")
      assert has_element?(lv, "#synced-group-#{last_group.id} button", "Remove access mapping")

      render_click(lv, "delete_runner_access_mapping", %{"id" => last_access.id})
      refute has_element?(lv, "#synced-group-#{last_group.id}")
      assert has_element?(lv, "#group-access-#{provider.id}-pager a", "Back to first page")
      refute has_element?(lv, "#group-access-section-#{provider.id}", "No synced groups yet")

      lv
      |> element("#group-access-#{provider.id}-pager a", "Back to first page")
      |> render_click()

      assert has_element?(lv, "#group-access-section-#{provider.id}", "Group 01")
    end

    test "role mapping pages all synced groups, including unmapped groups", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      sync_numbered_groups(provider, 21)

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-access-#{provider.id}-pager", "20 / 21 total")
      refute has_element?(lv, "#synced-groups-#{provider.id}")

      first = lv |> element("#group-access-section-#{provider.id}") |> render()
      assert first =~ "Group 01"
      refute first =~ "Group 21"

      _html =
        lv
        |> element("#group-access-#{provider.id}-pager a", "Next →")
        |> render_click()

      second = lv |> element("#group-access-section-#{provider.id}") |> render()
      assert second =~ "Group 21"
      refute second =~ "Group 01"
    end

    test "the group picker searches the directory rather than listing it", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      sync_numbered_groups(provider, 21)
      sync_group(provider, "00g-oncall", "Incident responders")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "add_mapping_form", %{})

      opened = lv |> element("#create-mapping-#{provider.id}") |> render()
      assert opened =~ "Group 01"
      refute opened =~ "Incident responders"

      _html =
        lv
        |> form("#create-mapping-#{provider.id}", %{"group_search" => "oncall"})
        |> render_change()

      searched = lv |> element("#create-mapping-#{provider.id}") |> render()
      assert searched =~ "Incident responders"
      refute searched =~ "Group 01"

      _html =
        lv
        |> form("#create-mapping-#{provider.id}", %{"group_search" => "nothing-like-this"})
        |> render_change()

      missing = lv |> element("#create-mapping-#{provider.id}") |> render()
      assert missing =~ "No group matches that name or ID."
    end

    test "the role mapping composer starts with closed searchable pickers and require a group choice",
         %{
           conn: conn,
           account: account,
           provider: provider
         } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      for {event, cancel, picker, form_id} <- [
            {"add_mapping_form", "cancel_add_mapping", "role-group-picker", "create-mapping"}
          ] do
        render_click(lv, event, %{})

        assert has_element?(
                 lv,
                 "##{picker}-#{provider.id}[data-dropdown][phx-mounted]:not([open]) > summary",
                 "Select a directory group"
               )

        assert has_element?(
                 lv,
                 "##{picker}-#{provider.id} [data-dropdown-panel] input[data-dropdown-search]"
               )

        assert has_element?(lv, "##{form_id}-#{provider.id}-submit[disabled]")
        refute has_element?(lv, "##{form_id}-#{provider.id} > p", "Add mapping")
        render_click(lv, cancel, %{})
      end
    end

    test "searching for a replacement keeps the chosen group and role until another is selected",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner
         } do
      platform = sync_group(provider, "grp-platform", "Platform Engineers")
      oncall = sync_group(provider, "grp-oncall", "Incident responders")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "add_mapping_form", %{})

      lv
      |> element("#role-group-picker-#{provider.id} button", "Platform Engineers")
      |> render_click()

      assert has_element?(lv, "#create-mapping-#{provider.id}-submit[disabled]")

      lv
      |> form("#create-mapping-#{provider.id}", %{"mapping" => %{"role" => "operator"}})
      |> render_change()

      refute has_element?(lv, "#create-mapping-#{provider.id}-submit[disabled]")

      lv
      |> form("#create-mapping-#{provider.id}", %{"group_search" => "oncall"})
      |> render_change()

      assert has_element?(lv, "#role-group-picker-#{provider.id} > summary", "Platform Engineers")

      assert has_element?(
               lv,
               "#create-mapping-#{provider.id} input[name='mapping[directory_group_id]'][value='#{platform.id}']"
             )

      lv
      |> element("#role-group-picker-#{provider.id} button", "Incident responders")
      |> render_click()

      assert has_element?(
               lv,
               "#role-group-picker-#{provider.id} > summary",
               "Incident responders"
             )

      lv
      |> form("#create-mapping-#{provider.id}")
      |> render_submit()

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert mapping.directory_group_id == oncall.id
      assert mapping.role == :operator
    end

    test "maps a group the picker had to search for", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      sync_numbered_groups(provider, 21)
      late = sync_group(provider, "00g-oncall", "Incident responders")

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Off the readout's first page and out of the picker's first answer, so
      # only the search can reach it.
      refute lv |> element("#group-access-section-#{provider.id}") |> render() =~
               "Incident responders"

      render_click(lv, "add_mapping_form", %{})

      _searched =
        lv
        |> form("#create-mapping-#{provider.id}", %{"group_search" => "oncall"})
        |> render_change()

      render_click(lv, "select_group", %{"scope" => "role", "group_id" => late.id})

      html =
        lv
        |> form("#create-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "mapping" => %{"role" => "operator"}
        })
        |> render_submit()

      assert html =~ "Role mapping added."

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert mapping.directory_group_id == late.id
    end

    test "a duplicate role mapping shows the group error and preserves the selected role", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "role-dupe", "Platform Engineers")
      replacement = sync_group(provider, "role-other", "Security Review")

      {:ok, original} =
        SSO.create_group_mapping(
          provider,
          %{"directory_group_id" => group.id, "role" => "operator"},
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "add_mapping_form", %{})
      render_click(lv, "select_group", %{"scope" => "role", "group_id" => group.id})

      lv
      |> form("#create-mapping-#{provider.id}", %{"mapping" => %{"role" => "admin"}})
      |> render_submit()

      assert has_element?(
               lv,
               "#role-group-picker-#{provider.id} + p",
               "This group already has a role mapping."
             )

      assert has_element?(lv, "#role-group-picker-#{provider.id} > summary", "Platform Engineers")
      assert has_element?(lv, "#create-mapping-#{provider.id} option[value='admin'][selected]")

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [unchanged] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert unchanged.id == original.id
      assert unchanged.role == :operator

      render_click(lv, "select_group", %{"scope" => "role", "group_id" => replacement.id})
      lv |> form("#create-mapping-#{provider.id}") |> render_submit()

      refute has_element?(
               lv,
               "#role-group-picker-#{provider.id} + p",
               "This group already has a role mapping."
             )

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      mappings = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert Enum.any?(mappings, &(&1.directory_group_id == replacement.id and &1.role == :admin))
    end

    test "a concurrent access mapping stays unchanged and the row keeps the rejected draft", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      group = sync_group(provider, "access-dupe", "Database team")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "edit_group_access", %{"group_id" => group.id})

      {:ok, original} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            "directory_group_id" => group.id,
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          },
          owner
        )

      refresh_directory(lv)

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all"}
      })
      |> render_change()

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all", "pack_access_mode" => "all"}
      })
      |> render_submit()

      assert has_element?(
               lv,
               "#synced-group-#{group.id} #group-access-error-#{group.id}",
               "This group already has an access mapping."
             )

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[name='runner_access_mapping[runner_access_mode]'][value='all'][checked]"
             )

      assert {:ok, group_rows, _metadata} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [unchanged] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      assert unchanged.id == original.id
      assert unchanged.runner_access_mode == :restricted
      assert unchanged.runner_scope_runner_ids == [runner.id]
    end

    test "edits a mapping's role while its synced group identity and display stay fixed", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "00g-eng", "Eng")

      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{
            "directory_group_id" => group.id,
            "role" => "operator"
          },
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")
      refute has_element?(lv, "#group-role-#{group.id} button[phx-value-role='operator']")
      assert has_element?(lv, "#delete-mapping-#{mapping.id}")
      refute has_element?(lv, "#synced-group-#{group.id} form")

      html =
        lv
        |> element("#group-role-#{group.id} button[phx-value-role='admin']")
        |> render_click()

      assert html =~ "Role mapping updated."
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Admin")

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [updated] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert updated.id == mapping.id
      assert updated.directory_group_id == group.id
      assert updated.external_group_id == "00g-eng"
      assert updated.external_group_display == "Eng"
      assert updated.role == :admin
    end

    test "edits access beneath its group with shared selectors and resets only the access grant",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner,
           user: user
         } do
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      group = sync_group(provider, "grp-database", "Database team")

      {:ok, role} =
        SSO.create_group_mapping(
          provider,
          %{directory_group_id: group.id, role: :operator},
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-access-section-#{provider.id} h2", "Groups & access")
      refute has_element?(lv, "#runner-access-mapping-section-#{provider.id}")
      refute has_element?(lv, "#connection-role-summary")
      refute has_element?(lv, "#connection-access-summary")
      refute has_element?(lv, "#synced-group-#{group.id}", "Default")
      assert has_element?(lv, "#group-access-facts-#{group.id}", "None")
      assert has_element?(lv, "#group-actions-#{group.id} > #group-role-#{group.id}")

      assert has_element?(
               lv,
               "#group-actions-#{group.id} > #edit-group-access-#{group.id}-toggle[aria-expanded='false']",
               "Edit access"
             )

      lv |> element("#edit-group-access-#{group.id}-toggle") |> render_click()

      assert has_element?(lv, "#synced-group-#{group.id} #edit-group-access-#{group.id}")
      refute has_element?(lv, "#synced-group-#{group.id}[class~='border-dashed']")
      refute has_element?(lv, "#synced-group-#{group.id}[class~='px-4']")
      refute has_element?(lv, "#synced-group-#{group.id}[class*='bg-']")
      refute has_element?(lv, "#synced-group-#{group.id}[class*='ring-']")

      assert has_element?(
               lv,
               "#group-actions-#{group.id} > #edit-group-access-#{group.id}-toggle[aria-expanded='true']",
               "Cancel edit"
             )

      assert has_element?(lv, "#edit-group-access-#{group.id}", "No runners")
      assert has_element?(lv, "#edit-group-access-#{group.id}", "No packs")

      refute has_element?(
               lv,
               "#synced-group-#{group.id}",
               "Connection defaults and other group grants still apply."
             )

      refute has_element?(lv, "#edit-group-access-#{group.id} [name='group_search']")

      refute has_element?(
               lv,
               "#edit-group-access-#{group.id} [name='runner_access_mapping[directory_group_id]']"
             )

      for field <- ~w(runner_access_mode pack_access_mode) do
        assert has_element?(
                 lv,
                 "#edit-group-access-#{group.id} input[type='radio'][name='runner_access_mapping[#{field}]'][value='none'][checked]"
               )

        refute has_element?(
                 lv,
                 "#edit-group-access-#{group.id} select[name='runner_access_mapping[#{field}]']"
               )
      end

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "restricted"}
      })
      |> render_change()

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[type='checkbox'][name='runner_access_mapping[scope][]'][value='group:database']"
             )

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[type='checkbox'][name='runner_access_mapping[scope][]'][value='runner:#{runner.id}']"
             )

      invalid =
        lv
        |> form("#edit-group-access-#{group.id}", %{
          "runner_access_mapping" => %{
            "runner_access_mode" => "restricted",
            "pack_access_mode" => "all"
          }
        })
        |> render_submit()

      assert invalid =~ "Choose all runners or at least one selected runner scope."
      assert has_element?(lv, "#group-access-error-#{group.id}")

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all", "pack_access_mode" => "all"}
      })
      |> render_change()

      refute has_element?(lv, "#group-access-error-#{group.id}")

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "restricted"}
      })
      |> render_change()

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{
          "runner_access_mode" => "restricted",
          "scope" => ["group:database"],
          "pack_access_mode" => "all"
        }
      })
      |> render_submit()

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))
      assert mapping.directory_group_id == group.id
      assert mapping.runner_scope_groups == ["database"]
      assert has_element?(lv, "#group-access-facts-#{group.id}", "database")
      refute has_element?(lv, "#synced-group-#{group.id}", "Default")
      refute has_element?(lv, "#group-access-error-#{group.id}")

      render_click(lv, "edit_group_access", %{"group_id" => group.id})

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[type='checkbox'][value='group:database'][checked]"
             )

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[type='checkbox'][value='runner:#{runner.id}'][disabled]"
             )

      assert has_element?(lv, "#save-group-access-#{group.id}[phx-hook='PendingButton']")

      lv
      |> form("#edit-group-access-#{group.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all"}
      })
      |> render_submit()

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [%{runner_access_mode: :all}] =
               Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      render_click(lv, "edit_group_access", %{"group_id" => group.id})

      assert has_element?(
               lv,
               "#delete-runner-access-mapping-#{mapping.id}-confirm",
               "Reset to defaults"
             )

      lv |> element("#delete-runner-access-mapping-#{mapping.id}-confirm") |> render_click()

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [retained_role] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert retained_role.id == role.id
      refute has_element?(lv, "#connection-access-summary")
      refute has_element?(lv, "#synced-group-#{group.id}", "Default")
      assert has_element?(lv, "#group-access-facts-#{group.id}", "None")
      assert has_element?(lv, "#group-role-#{group.id} > summary", "Operator")
    end

    test "access editing preserves drafts, toggles closed, and recovers when its group disappears",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner
         } do
      first = sync_group(provider, "draft-first", "First group")
      second = sync_group(provider, "draft-second", "Second group")

      {:ok, retired_mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{directory_group_id: second.id, runner_access_mode: :all},
          owner
        )

      {:ok, _} = SSO.scim_delete_group(provider, second.id)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      render_click(lv, "edit_group_access", %{"group_id" => first.id})

      lv
      |> form("#edit-group-access-#{first.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all"}
      })
      |> render_change()

      lv
      |> form("#edit-group-access-#{first.id}", %{
        "runner_access_mapping" => %{"runner_access_mode" => "all", "pack_access_mode" => "all"}
      })
      |> render_change()

      refresh_directory(lv)
      render_click(lv, "delete_runner_access_mapping", %{"id" => retired_mapping.id})

      assert has_element?(
               lv,
               "#edit-group-access-#{first.id} input[name='runner_access_mapping[runner_access_mode]'][value='all'][checked]"
             )

      render_click(lv, "edit_group_access", %{"group_id" => first.id})
      refute has_element?(lv, "#edit-group-access-#{first.id}")
      render_click(lv, "edit_group_access", %{"group_id" => first.id})

      assert has_element?(
               lv,
               "#edit-group-access-#{first.id} input[name='runner_access_mapping[runner_access_mode]'][value='none'][checked]"
             )

      third = sync_group(provider, "draft-third", "Third group")
      refresh_directory(lv)
      render_click(lv, "edit_group_access", %{"group_id" => third.id})
      assert has_element?(lv, "#edit-group-access-#{first.id}")
      refute has_element?(lv, "#edit-group-access-#{third.id}")
      assert has_element?(lv, "#synced-group-#{third.id} button[disabled]", "Edit access")

      {:ok, _} = SSO.scim_delete_group(provider, first.id)
      refresh_directory(lv)
      refute has_element?(lv, "#edit-group-access-#{first.id}")
      assert render(lv) =~ "unsaved access changes were discarded"
      lv |> element("#edit-group-access-#{third.id}-toggle") |> render_click()
      assert has_element?(lv, "#edit-group-access-#{third.id}")
    end

    test "all defaults lock both dimensions and saving exactly defaults removes redundant additions",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner
         } do
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      {:ok, provider} =
        SSO.update_provider(
          provider,
          %{
            default_runner_access_mode: :all,
            default_pack_access_mode: :all
          },
          owner
        )

      group = sync_group(provider, "grant-only", "Grant only")

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            directory_group_id: group.id,
            runner_access_mode: :restricted,
            scope: ["runner:#{runner.id}"]
          },
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-access-facts-#{group.id}", "All")
      refute has_element?(lv, "#synced-group-#{group.id}", "Default")
      refute has_element?(lv, "#connection-access-summary")
      render_click(lv, "edit_group_access", %{"group_id" => group.id})

      for field <- ~w(runner_access_mode pack_access_mode) do
        assert has_element?(
                 lv,
                 "#edit-group-access-#{group.id} input[name='runner_access_mapping[#{field}]'][value='all'][checked][disabled]"
               )

        assert has_element?(
                 lv,
                 "#edit-group-access-#{group.id} input[name='runner_access_mapping[#{field}]'][value='none'][disabled]"
               )
      end

      lv |> form("#edit-group-access-#{group.id}") |> render_submit()

      assert {:ok, group_rows, _} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))
    end

    test "access editor selects and locks named defaults without saving them as additions", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      Fixtures.Runners.create_runner(account_id: account.id, group: "database")

      runner =
        Fixtures.Runners.create_runner(account_id: account.id, group: "api", name: "api-primary")

      {:ok, provider} =
        SSO.update_provider(
          provider,
          %{
            default_runner_access_mode: :restricted,
            default_runner_scope: ["group:database", "runner:#{runner.id}"],
            default_pack_access_mode: :all
          },
          owner
        )

      group = sync_group(provider, "named-defaults", "Named defaults")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      refute has_element?(lv, "#connection-access-summary")
      lv |> element("#edit-group-access-#{group.id}-toggle") |> render_click()

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[value='group:database'][checked][disabled]"
             )

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[value='runner:#{runner.id}'][checked][disabled]"
             )

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[name='runner_access_mapping[pack_access_mode]'][value='all'][checked][disabled]"
             )

      assert {:ok, group_rows, _} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      # A live baseline change moves the locks, not the stored draft additions.
      {:ok, _} = SSO.update_provider(provider, %{default_runner_access_mode: :all}, owner)
      refresh_directory(lv)

      assert has_element?(
               lv,
               "#edit-group-access-#{group.id} input[name='runner_access_mapping[runner_access_mode]'][value='all'][checked][disabled]"
             )

      assert :sys.get_state(lv.pid).socket.assigns.group_access_editor.form.source.changes.runner_access_mode ==
               :none

      lv |> element("#edit-group-access-#{group.id}-toggle") |> render_click()
      refute has_element?(lv, "#connection-access-summary")
      assert has_element?(lv, "#group-access-facts-#{group.id}", "All")
    end

    test "access editor binds every submit to the opened row and rejects foreign targets", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      first = sync_group(provider, "bound-first", "First group")
      second = sync_group(provider, "bound-second", "Second group")
      other_provider = insert_provider(account, %{kind: :entra})
      {:ok, other_provider, _} = SSO.enable_scim(other_provider, owner)
      foreign = sync_group(other_provider, "foreign", "Foreign group")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "edit_group_access", %{"group_id" => foreign.id})
      refute has_element?(lv, "form[phx-submit='save_group_access']")

      render_click(lv, "save_group_access", %{
        "group_id" => first.id,
        "runner_access_mapping" => %{"runner_access_mode" => "all"}
      })

      assert {:ok, group_rows, _} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      render_click(lv, "edit_group_access", %{"group_id" => first.id})

      for bad_id <- [second.id, foreign.id, Ecto.UUID.generate()] do
        render_click(lv, "save_group_access", %{
          "group_id" => bad_id,
          "runner_access_mapping" => %{"runner_access_mode" => "all"}
        })
      end

      for event <- ["edit_group_access", "validate_group_access", "save_group_access"] do
        render_click(lv, event, %{"runner_access_mapping" => "not a map"})
      end

      assert {:ok, group_rows, _} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))

      render_click(lv, "save_group_access", %{
        "group_id" => first.id,
        "runner_access_mapping" => %{
          "directory_group_id" => foreign.id,
          "provider_id" => other_provider.id,
          "runner_access_mode" => "all",
          "pack_access_mode" => "all"
        }
      })

      assert {:ok, group_rows, _} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [mapping] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))
      assert mapping.directory_group_id == first.id
      assert mapping.provider_id == provider.id

      assert {:ok, group_rows, _} =
               SSO.list_group_access(other_provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.runner_access_mapping))
    end

    test "a viewer cannot open, save, or reset group access through forged events", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner,
      user: user
    } do
      group = sync_group(provider, "denied", "Denied group")

      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{directory_group_id: group.id, runner_access_mode: :all},
          owner
        )

      make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      render_click(lv, "edit_group_access", %{"group_id" => group.id})

      render_click(lv, "save_group_access", %{
        "group_id" => group.id,
        "runner_access_mapping" => %{"runner_access_mode" => "all"}
      })

      render_click(lv, "delete_runner_access_mapping", %{"id" => mapping.id})
      refute has_element?(lv, "form[phx-submit='save_group_access']")
      unchanged = Repo.reload!(mapping)
      assert is_nil(unchanged.deleted_at)
      assert unchanged.runner_access_mode == :all
    end

    test "an open access editor cannot save or reset after the plan is downgraded", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "downgraded", "Downgraded group")

      {:ok, mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{directory_group_id: group.id, runner_access_mode: :all},
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "edit_group_access", %{"group_id" => group.id})
      Fixtures.Accounts.create_subscription(account, "enterprise", status: "canceled")

      render_click(lv, "save_group_access", %{
        "group_id" => group.id,
        "runner_access_mapping" => %{"runner_access_mode" => "restricted", "scope" => []}
      })

      render_click(lv, "delete_runner_access_mapping", %{"id" => mapping.id})
      unchanged = Repo.reload!(mapping)
      assert is_nil(unchanged.deleted_at)
      assert unchanged.runner_access_mode == :all
      refresh_directory(lv)
      refute has_element?(lv, "form[phx-submit='save_group_access']")
    end

    test "a mapped runner scope names the live runner without exposing its ID", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r20", group: "database")

      group = sync_group(provider, "grp-database", "Database team")

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            "directory_group_id" => group.id,
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          },
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-access-section-#{provider.id}", "r20")
      refute has_element?(lv, "[title='#{runner.id}']")
    end

    test "a mapped runner scope that no longer resolves reads as unavailable without exposing its ID",
         %{
           conn: conn,
           account: account,
           provider: provider,
           owner: owner
         } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r21", group: "database")

      group = sync_group(provider, "grp-database", "Database team")

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            "directory_group_id" => group.id,
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          },
          owner
        )

      # The mapping outlives the runner row; the chip stays honest instead of
      # printing an unreadable id prefix.
      {:ok, _deleted} = Emisar.Runners.delete_runner(runner, owner)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#group-access-section-#{provider.id}", "Runner unavailable")
      refute html =~ "r21"
    end

    test "an IdP group without an external id uses the lowercase emisar fallback", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      assert {:ok, %{identity: identity}} =
               SSO.scim_provision_user(provider, %{
                 external_id: "user-with-server-owned-group",
                 email: "server-owned-group@example.com",
                 full_name: "Server-owned group member"
               })

      assert {:ok, group} =
               SSO.scim_upsert_group(provider, %{
                 external_id: nil,
                 display: "Server-owned group",
                 member_ids: [identity.id]
               })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "emisar group #{group.id}"
      refute html =~ "Emisar group"
    end

    test "the role select never offers Owner; a forced owner mapping is rejected inline", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "grp-owner", "Owners")
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Reveal the add form (behind the "Add mapping" button), then read its role select.
      render_click(lv, "add_mapping_form", %{})

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
          "mapping" => %{"directory_group_id" => group.id, "role" => "owner"}
        })

      assert rejected =~ "directory sync cannot grant owner"

      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "a non-admin viewer cannot create a role mapping", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      group = sync_group(provider, "viewer-forged", "Viewer forged group")
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => "admin"})
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      refute has_element?(lv, "#group-role-#{group.id}")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly.
      _ =
        render_click(lv, "create_mapping", %{
          "provider_id" => provider.id,
          "mapping" => %{"external_group_id" => "grp", "role" => "admin"}
        })

      # No mapping was created (read it back through the pre-demotion owner subject).
      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
    end

    test "a non-admin viewer cannot update or delete a role mapping (forged events)", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      # The admin seeds a mapping; after the role drops to viewer the update and
      # delete handlers (Permissions.gated + context `manage_sso`) refuse forged
      # events — the mapping keeps its role and is never soft-deleted.
      group = sync_group(provider, "00g-keep", "Keep")

      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{"directory_group_id" => group.id, "role" => "operator"},
          owner
        )

      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      _ =
        render_click(lv, "set_group_role", %{"group_id" => group.id, "role" => "admin"})

      _ = render_click(lv, "delete_mapping", %{"id" => mapping.id})

      # Unchanged and present — read back through the pre-demotion owner subject.
      assert {:ok, group_rows, _meta} =
               SSO.list_group_access(provider, owner, page: [limit: 100])

      assert [unchanged] = Enum.flat_map(group_rows, &List.wrap(&1.mapping))
      assert unchanged.id == mapping.id
      assert unchanged.role == :operator
    end
  end

  describe "as a free account" do
    test "the Add page shows the paid-plan upsell, not the form", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "free"}})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      # An OWNER holds the permission — this lock is the PLAN's, so it upsells.
      assert html =~ "Single sign-on is a paid feature"
      assert html =~ "See plans"
      refute has_element?(lv, "#provider_form")
    end
  end

  describe "as a Team account" do
    test "the Add page shows the OIDC config, not the plan upsell", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "team"}})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      refute html =~ "Single sign-on is a paid feature"
      assert has_element?(lv, "#provider_form")
    end

    test "the SCIM upsell sales link carries account/user context", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "team"}})
      provider = insert_provider(account, %{})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~
               "Sync members and groups from your identity provider with the Enterprise plan."

      assert html =~ "mailto:sales@emisar.dev"
      assert html =~ "subject=SCIM%20directory%20sync%20-%20Test%20Co"
      assert html =~ "Account%20ID%3A%20#{account.id}"
      assert html =~ "User%3A%20#{String.replace(user.email, "@", "%40")}"
    end
  end

  describe "as a non-admin member" do
    test "an enterprise viewer is denied the Add page and sees the role gate", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      _ = make_viewer(user)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      assert html =~ "Single sign-on settings are restricted"
      refute has_element?(lv, "#provider_form")
    end
  end

  # Placed at the end (not in the "synced members" describe above) only to keep a clean
  # commit apart from that describe's in-flight rework — logically it belongs there.
  describe "synced members — a directory-synced role is read-only" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})
      {:ok, provider} = provider |> Ecto.Changeset.change(scim_enabled: true) |> Repo.update()

      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{
          external_id: "kc|erin",
          email: "erin@northstar.example",
          full_name: "Erin Sync"
        })

      # A sync recompute marks the role directory-managed — the domain-owned signal
      # `update_membership_role` refuses on (a real synced member has been synced).
      {:ok, membership} = SSO.recompute_role_for_identity(provider, identity)

      %{conn: conn, account: account, provider: provider, membership: membership}
    end

    test "the role has no editable select and a crafted change_member_role is refused", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Directory sync owns the role (recomputed each sync), so the row shows it
      # read-only — no editable <select> — and a crafted change_member_role is rejected
      # at the domain, leaving the role untouched.
      refute has_element?(lv, ~s(select[name="role"]))

      render_click(lv, "change_member_role", %{
        "membership_id" => membership.id,
        "role" => "admin"
      })

      assert Repo.reload!(membership).role == membership.role
    end
  end

  describe "synced members — a provider without directory sync keeps an editable role" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})
      owner = Fixtures.Subjects.subject_for(user, account)
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)

      {:ok, %{identity: identity}} =
        SSO.scim_provision_user(provider, %{
          external_id: "kc|frankie",
          email: "frankie@northstar.example",
          full_name: "Frankie Link"
        })

      membership = Accounts.peek_sync_membership(provider.account_id, identity.user_id)
      {:ok, provider} = SSO.disable_scim(provider, owner)

      %{conn: conn, account: account, provider: provider, membership: membership}
    end

    test "the role change routes through a per-role confirm dialog, not a bare select", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      # No directory sync on this provider, so the role is editable — but a role
      # change is a privilege grant, so it goes through the same styled confirm as
      # the Team roster: a per-role confirm modal, never a bare select that would
      # promote to owner on a single change.
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.none())
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The promote-on-change select is gone; a confirm dialog exists for every
      # OTHER role, and the owner one spells out the consequence.
      refute has_element?(lv, ~s(select[name="role"]))
      assert has_element?(lv, "#synced-role-#{membership.id}-owner")
      refute has_element?(lv, "#synced-role-#{membership.id}-owner", "credentials")
      refute has_element?(lv, "#synced-role-#{membership.id}-owner", "reconnect")
      assert render(lv) =~ "They can delete the account and remove or demote you."

      assert has_element?(
               lv,
               "#synced-role-#{membership.id}-admin p + p.mt-3",
               "Actions → Edit access on the Team page"
             )

      refute has_element?(lv, "#synced-role-#{membership.id}-owner p + p")

      # Confirming a role (the dialog's on_confirm pushes change_member_role) lands it.
      new_role = if membership.role == :operator, do: "viewer", else: "operator"

      render_click(lv, "change_member_role", %{
        "membership_id" => membership.id,
        "role" => new_role
      })

      assert to_string(Repo.reload!(membership).role) == new_role
    end

    test "a crafted change_member_role with an unknown role is refused", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      html =
        render_click(lv, "change_member_role", %{
          "membership_id" => membership.id,
          "role" => "superadmin"
        })

      assert html =~ "That change wasn&#39;t valid."
      assert Repo.reload!(membership).role == membership.role
    end
  end

  describe "directory request history and setup instructions" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})
      {:ok, provider} = provider |> Ecto.Changeset.change(scim_enabled: true) |> Repo.update()
      %{conn: conn, account: account, provider: provider}
    end

    test "waits for the first request without a historical timestamp", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Enabled")

      assert has_element?(
               lv,
               "#scim-request-status-#{provider.id}",
               "(waiting for first request)"
             )

      refute has_element?(lv, "#scim-last-request-#{provider.id}")

      assert has_element?(
               lv,
               "#scim-setup-#{provider.id}:not([open]) summary",
               "Setup instructions"
             )
    end

    test "recent and old requests keep the same status and available setup instructions", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      for age <- [0, 86_400, 7 * 86_400] do
        last_request = DateTime.add(DateTime.utc_now(), -age, :second)

        provider
        |> Ecto.Changeset.change(scim_last_seen_at: last_request)
        |> Repo.update!()

        {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

        assert has_element?(lv, "#scim-enabled-status-#{provider.id}", "Enabled")

        assert has_element?(
                 lv,
                 "#scim-enabled-status-#{provider.id} > span.text-brand-300",
                 "Enabled"
               )

        assert has_element?(
                 lv,
                 "#scim-enabled-status-#{provider.id} > #scim-request-status-#{provider.id}.text-zinc-400",
                 "(last request"
               )

        assert has_element?(
                 lv,
                 "#scim-request-status-#{provider.id} #scim-last-request-#{provider.id}"
               )

        refute has_element?(lv, "#scim-request-status-#{provider.id} .text-brand-300")

        assert has_element?(
                 lv,
                 "#scim-last-request-#{provider.id}[datetime='#{DateTime.to_iso8601(last_request)}']"
               )

        refute has_element?(
                 lv,
                 "#scim-request-status-#{provider.id}",
                 "waiting for first request"
               )

        assert has_element?(
                 lv,
                 "#scim-setup-#{provider.id}:not([open]) summary",
                 "Setup instructions"
               )
      end
    end
  end
end

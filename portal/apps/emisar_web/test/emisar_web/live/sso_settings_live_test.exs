defmodule EmisarWeb.SSOSettingsLiveTest do
  @moduledoc """
  The SSO settings pages — an overview (`/settings/sso`: pending access requests +
  the connections list + the team sign-in link) and a per-connection detail
  (`/settings/sso/:id`: status, edit, directory sync, group→role mapping). Access
  is plan-gated (Team for OIDC, Enterprise for SCIM) AND permission-gated
  (`manage_sso`, owners/admins): a non-admin member or a free account sees the
  upsell instead of a crash, and a cross-account connection id reads as not found.
  """
  use EmisarWeb.ConnCase, async: true
  alias Emisar.Repo
  alias Emisar.SSO
  alias Emisar.SSO.{IdentityProvider, LinkRequest, UserIdentity}

  defp make_viewer(user) do
    {:ok, membership} = Emisar.Accounts.fetch_membership_for_session(user, nil)
    Fixtures.Memberships.force_role(membership, "viewer")
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

    test "renders the config surface, not the upsell", %{conn: conn, account: account} do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Add connection"
      refute html =~ "Enterprise feature"

      # Adding a connection is its own view (with the per-provider setup guide).
      {:ok, _lv, new_html} = live(conn, ~p"/app/#{account}/settings/sso/new")
      assert new_html =~ "Add an identity provider"
      assert new_html =~ "/sign_in/sso/callback"
    end

    test "surfaces the branded sign-in link to share with the team", %{
      conn: conn,
      account: account
    } do
      # No provider is seeded here, yet the branded sign-in link card still
      # renders — it's unconditional (email sign-in works without SSO), not gated
      # on having a connection.
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "sign-in link"
      # Absolute, slug-based — copy-pasteable straight into onboarding docs.
      assert html =~ "/app/#{account.slug}/sign_in"
    end

    test "lists existing connections", %{conn: conn, account: account} do
      _provider = insert_provider(account, %{name: "Acme Okta"})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Acme Okta"
      assert html =~ "Enabled"
    end

    test "creates a connection through the form, then returns to the list", %{
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

      # Adding is its own view; a successful create navigates back to the list.
      assert_redirect(lv, ~p"/app/#{account}/settings/sso")

      assert IdentityProvider.Query.not_deleted()
             |> IdentityProvider.Query.ordered_by_name()
             |> Repo.all()
             |> Enum.any?(&(&1.name == "Work Okta"))

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")
      assert html =~ "Work Okta"
    end

    test "opens the inline edit form without leaking the stored secret", %{
      conn: conn,
      account: account
    } do
      provider = insert_provider(account, %{client_secret: "super-secret-value-xyz"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Opening the edit form on the detail page must never render the stored,
      # write-only client_secret back — the field is blank ("leave to keep").
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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      _ = render_hook(lv, "start_edit", %{"id" => provider.id})

      # Submit the inline edit with a BLANK client_secret (the field is never
      # pre-filled). strip_blank_secret drops it, so the stored value is kept.
      lv
      |> form("#edit-provider-#{provider.id}", %{
        "provider_id" => provider.id,
        "provider" => %{
          "kind" => "okta",
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

      assert_redirect(lv, ~p"/app/#{account}/settings/sso")

      provider =
        IdentityProvider.Query.not_deleted()
        |> IdentityProvider.Query.ordered_by_name()
        |> Repo.all()
        |> Enum.find(&(&1.name == "Defaults Okta"))

      # The schema's documented defaults: stable identifier is `sub`, the
      # provider satisfies the account MFA gate, and it's created DISABLED so it
      # can't be signed in through until the admin explicitly turns it on.
      assert provider.identifier_claim == :sub
      assert provider.satisfies_mfa == true
      assert provider.enabled == false
      assert provider.provisioner == :jit
    end

    test "a crafted create event is refused when the plan is downgraded mid-form", %{
      conn: conn,
      account: account
    } do
      # Mount on Enterprise (can_configure? is true, cached at mount), then drop
      # the account to the free tier by removing its subscription — exactly the
      # mid-form downgrade the row describes. The cached gate lets the event
      # through to the context, which re-checks the live plan and rejects it.
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      {_deleted, _} =
        Emisar.Billing.Subscription.Query.all()
        |> Emisar.Billing.Subscription.Query.by_account_id(account.id)
        |> Repo.delete_all()

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

      assert html =~ "Single sign-on requires an Enterprise plan."

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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

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

    test "approve/dismiss of an already-consumed request id is a graceful no-op", %{
      conn: conn,
      account: account
    } do
      # A request the admin already actioned (or that a second tab consumed) is
      # gone from the loaded list, so with_request finds nothing and both handlers
      # short-circuit — no flash, no crash.
      provider = insert_provider(account, %{name: "Manual Okta", provisioner: :manual})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      ghost_id = Ecto.UUID.generate()

      approve_html = render_click(lv, "approve_request", %{"id" => ghost_id})
      refute approve_html =~ "approved"

      dismiss_html = render_click(lv, "dismiss_request", %{"id" => ghost_id})
      refute dismiss_html =~ "dismissed"

      _ = provider
    end
  end

  describe "the connection detail page" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, user: user, account: account}
    end

    test "renders just the one connection, with its config controls", %{
      conn: conn,
      account: account
    } do
      shown = insert_provider(account, %{name: "Acme Okta"})
      _other = insert_provider(account, %{name: "Globex Google", kind: :google_workspace})

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{shown.id}")

      assert html =~ "Acme Okta"
      # The per-connection delete dialog is detail-only (never on the overview list).
      assert has_element?(lv, "#delete-provider-#{shown.id}")
      # A single-connection view — the other connection isn't on this page.
      refute html =~ "Globex Google"
    end

    test "a connection from another account reads as not found — back to the overview", %{
      conn: conn,
      account: account
    } do
      other_account = Fixtures.Accounts.create_account(%{plan: "enterprise"})
      foreign = insert_provider(other_account, %{name: "Other Co Okta"})

      dest = ~p"/app/#{account}/settings/sso"

      assert {:error, {:live_redirect, %{to: ^dest}}} =
               live(conn, ~p"/app/#{account}/settings/sso/#{foreign.id}")
    end

    test "an unknown connection id reads as not found — back to the overview", %{
      conn: conn,
      account: account
    } do
      dest = ~p"/app/#{account}/settings/sso"

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

      assert html =~ "Single sign-on is a paid feature"
      refute html =~ "Acme Okta"
    end
  end

  describe "group → role mapping forms gating" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      %{conn: conn, account: account}
    end

    test "a connection without directory sync shows no group→role mapping form", %{
      conn: conn,
      account: account
    } do
      # Group→role mappings are a SCIM feature — the create/edit forms (and the
      # "Group → role mapping" panel) render only when `scim_enabled`. A freshly
      # created connection is SCIM-off (enable_scim turns it on), so it must not
      # surface them.
      provider = insert_provider(account, %{name: "No SCIM Okta"})
      refute Repo.reload!(provider).scim_enabled
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The connection itself renders…
      assert html =~ "No SCIM Okta"
      # …but the mapping panel + its create form don't (the section is gated on
      # scim_enabled).
      refute html =~ "Group → role mapping"
      refute has_element?(lv, "#create-mapping-#{provider.id}")
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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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

      # And a fresh mount never re-renders it (write-only, like client_secret).
      {:ok, _lv2, remounted} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")
      refute remounted =~ token
      # Directory sync still shows as on, just without the secret.
      assert remounted =~ "Directory sync (SCIM)"
    end

    test "rotate issues a new token; disable turns sync off", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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
      account: account,
      user: user,
      provider: provider
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

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
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      _ = render_click(lv, "rotate_scim", %{"id" => provider.id})
      _ = render_click(lv, "disable_scim", %{"id" => provider.id})

      # Still enabled, and the prefix is the admin-minted one (no rotation landed).
      reloaded = Repo.reload!(provider)
      assert reloaded.scim_enabled
      assert reloaded.scim_token_prefix == prefix
    end
  end

  describe "group → role mapping" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      owner = Fixtures.Subjects.subject_for(user, account)
      provider = insert_provider(account, %{name: "Acme Okta"})
      {:ok, provider, _raw} = SSO.enable_scim(provider, owner)
      %{conn: conn, user: user, account: account, provider: provider, owner: owner}
    end

    test "creates, lists, and deletes a group mapping", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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

    test "edits a mapping's display + role through the inline edit form", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{
            "external_group_id" => "00g-eng",
            "external_group_display" => "Eng",
            "role" => "operator"
          },
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # Open the inline editor for this mapping (the externalId is the immutable
      # key; only display + role are editable).
      _ = render_click(lv, "start_edit_mapping", %{"id" => mapping.id})

      html =
        lv
        |> form("#edit-mapping-#{mapping.id}", %{
          "mapping_id" => mapping.id,
          "mapping" => %{"external_group_display" => "Engineering", "role" => "admin"}
        })
        |> render_submit()

      assert html =~ "Group mapping updated."

      {:ok, [updated], _meta} = SSO.list_group_mappings(provider, owner)
      assert updated.id == mapping.id
      # The externalId (immutable key) is unchanged; display + role applied.
      assert updated.external_group_id == "00g-eng"
      assert updated.external_group_display == "Engineering"
      assert updated.role == :admin
    end

    test "the role select never offers Owner; a forced owner mapping is rejected inline", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

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

    test "a non-admin viewer cannot update or delete a group mapping (forged events)", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      # The admin seeds a mapping; after the role drops to viewer the update and
      # delete handlers (Permissions.gated + context `manage_sso`) refuse forged
      # events — the mapping keeps its role and is never soft-deleted.
      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{"external_group_id" => "00g-keep", "role" => "operator"},
          owner
        )

      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      _ =
        render_submit(lv, "update_mapping", %{
          "mapping_id" => mapping.id,
          "mapping" => %{"role" => "admin"}
        })

      _ = render_click(lv, "delete_mapping", %{"id" => mapping.id})

      # Unchanged and present — read back through the pre-demotion owner subject.
      assert {:ok, [unchanged], _meta} = SSO.list_group_mappings(provider, owner)
      assert unchanged.id == mapping.id
      assert unchanged.role == :operator
    end
  end

  describe "manual link requests" do
    setup %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      owner = Fixtures.Subjects.subject_for(user, account)

      provider =
        insert_provider(account, %{
          name: "Manual Okta",
          provisioner: :manual,
          default_role: :operator
        })

      %{conn: conn, user: user, account: account, provider: provider, owner: owner}
    end

    test "the connection form offers the manual provisioning mode", %{
      conn: conn,
      account: account
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      assert html =~ "New-user provisioning"
      assert html =~ "an admin approves each new user"
    end

    test "lists pending requests with the captured identity", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      _ =
        insert_link_request(provider, %{
          provider_identifier: "okta|dana",
          full_name: "Dana Operator",
          email: "dana@acme.test"
        })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Pending access requests"
      assert html =~ "Dana Operator"
      assert html =~ "okta|dana"
    end

    test "a request matched to an existing member shows the link badge + warning", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      member = Fixtures.Users.create_user(%{email: "member@acme.test"})

      _ =
        Fixtures.Memberships.create_membership(
          account_id: account.id,
          user_id: member.id,
          role: :admin
        )

      _ =
        insert_link_request(provider, %{
          provider_identifier: "okta|member",
          email: "member@acme.test",
          matched_user_id: member.id
        })

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Existing account"
      assert html =~ "sign in as the existing member@acme.test account"
    end

    test "approve provisions the captured identity + clears the request", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|appr"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      html = render_click(lv, "approve_request", %{"id" => request.id})

      assert html =~ "approved"
      assert identity_bound?(provider, "okta|appr")
      assert {:ok, [], _meta} = SSO.list_link_requests(provider, owner)
    end

    test "dismiss removes the request without provisioning", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|dis"})
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      html = render_click(lv, "dismiss_request", %{"id" => request.id})

      assert html =~ "dismissed"
      refute identity_bound?(provider, "okta|dis")
      assert {:ok, [], _meta} = SSO.list_link_requests(provider, owner)
    end

    test "a non-admin viewer cannot approve a request", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      request = insert_link_request(provider, %{provider_identifier: "okta|vw"})
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso")

      # The viewer sees the upsell, not the panel; the gated event is a no-op
      # server-side even if pushed directly — the request stays pending.
      _ = render_click(lv, "approve_request", %{"id" => request.id})

      refute identity_bound?(provider, "okta|vw")
      assert {:ok, [_still_pending], _meta} = SSO.list_link_requests(provider, owner)
    end
  end

  describe "as a free account" do
    test "shows the paid-plan upsell instead of the config", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "free"}})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Single sign-on is a paid feature"
      assert html =~ "See plans"
      refute html =~ "Connect your organization"
    end
  end

  describe "as a Team account" do
    test "shows the OIDC config but gates SCIM behind Enterprise", %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "team"}})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      refute html =~ "Single sign-on is a paid feature"
      assert html =~ "Connect your organization"
    end
  end

  describe "as a non-admin member" do
    test "an enterprise viewer is denied the config and sees the upsell", %{conn: conn} do
      {conn, user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      _ = make_viewer(user)

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso")

      assert html =~ "Single sign-on is a paid feature"
      refute html =~ "Add an identity provider"
    end
  end
end

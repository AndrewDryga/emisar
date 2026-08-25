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
      {:ok, _lv, new_html} = live(conn, ~p"/app/#{account}/settings/sso/new")
      assert new_html =~ "Add connection"
      refute new_html =~ "Add an identity provider"
      assert new_html =~ "Member provisioning"
      refute new_html =~ "User provisioning"
      assert new_html =~ "/sign_in/sso/callback"
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

    test "the default-role picker is radio cards with per-role descriptions", %{
      conn: conn,
      account: account
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/new")

      assert html =~ ~s(name="provider[default_role]")
      assert html =~ ~s(type="radio")
      # A role's shared description renders on its card (viewer, here).
      assert html =~ "Read-only across runs"
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

      refute Repo.one(IdentityProvider)
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
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}/edit")

      assert html =~ "edit-provider-#{provider.id}"
      assert html =~ "Leave blank to keep current"
      refute html =~ "super-secret-value-xyz"
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

      assert html =~ "Single sign-on requires a Team or Enterprise plan."

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
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{off.id}")

      # Sign-in only: no mapping or synced-group sections, so their notes are
      # absent too — a note exists to explain the section beside it.
      refute html =~ "Adds runners on top of the connection default"
      refute html =~ "What your IdP has actually pushed"
      assert html =~ "Members added when they first signed in"

      owner = Fixtures.Subjects.subject_for(user, account)
      on = insert_provider(account, %{name: "Synced", kind: :entra})
      {:ok, on, _raw} = SSO.enable_scim(on, owner)
      {:ok, lv, synced} = live(conn, ~p"/app/#{account}/settings/sso/#{on.id}")

      for note <- [
            "Members and groups stay in sync",
            "Choose the role for each synced group",
            "Each mapping adds runner and pack access",
            "Groups received from your identity provider",
            "Suspend someone here for a temporary hold"
          ] do
        assert synced =~ note
      end

      assert synced =~ "remove their emisar access"
      refute synced =~ "remove their Emisar access"

      for {section_id, note} <- [
            {"directory-sync-#{on.id}", "Members and groups stay in sync"},
            {"role-mapping-section-#{on.id}", "Choose the role for each synced group"},
            {"runner-access-mapping-section-#{on.id}",
             "Each mapping adds runner and pack access"},
            {"synced-groups-#{on.id}", "Groups received from your identity provider"},
            {"synced-members-#{on.id}", "Suspend someone here for a temporary hold"}
          ] do
        assert has_element?(lv, "##{section_id} > div:first-child")
        assert has_element?(lv, "##{section_id} > div:nth-child(2)")
        assert has_element?(lv, "##{section_id} > aside##{section_id}-help", note)
      end

      # Actions stay in the primary header cell; the help rail begins only on
      # the content row below it.
      assert has_element?(
               lv,
               "#role-mapping-section-#{on.id} > div:first-child button",
               "Add mapping"
             )

      assert has_element?(
               lv,
               "#runner-access-mapping-section-#{on.id} > div:first-child button",
               "Add runner access"
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
      assert has_element?(lv, "#connection-summary dt", "Status")
      assert has_element?(lv, "#connection-summary dd", "Enabled")
      assert has_element?(lv, "#connection-summary dt", "Provider")
      assert has_element?(lv, "#connection-summary", "Connection settings")
      assert has_element?(lv, "#connection-summary > #connection-settings")
      assert has_element?(lv, "#connection-summary > #connection-docs", "Setting up")
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
      assert lv |> element("#connection-danger-zone") |> render() =~ "xl:col-span-2"
      # A single-connection view — the other connection isn't on this page.
      refute html =~ "Globex Google"
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

      assert html =~ "Single sign-on needs an owner or admin role."
      refute html =~ "Acme Okta"
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

      assert html =~ "https URL first"
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
      # Role mappings are a SCIM feature — the create/edit forms (and the
      # "Role mapping" panel) render only when `scim_enabled`. A freshly
      # created connection is SCIM-off (enable_scim turns it on), so it must not
      # surface them.
      provider = insert_provider(account, %{name: "No SCIM Okta"})
      refute Repo.reload!(provider).scim_enabled
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The connection itself renders…
      assert html =~ "No SCIM Okta"
      # …but the mapping panel + its create form don't (the section is gated on
      # scim_enabled).
      refute html =~ "Role mapping"
      refute has_element?(lv, "#create-mapping-#{provider.id}")
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
        "keycloak" => "Keycloak pushes no directory of its own",
        "google_workspace" => "Google Workspace can&#39;t push a directory"
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

      html = render_click(lv, "enable_scim", %{"id" => provider.id})

      assert html =~ "Directory sync enabled."
      assert html =~ "shown only once"
      assert html =~ "/scim/v2"
      assert html =~ "Members and groups stay in sync"
      # The freshly-minted ems- token is rendered exactly once, in the reveal.
      assert html =~ "ems-"
      # The IdP-side SCIM setup steps appear once sync is on.
      assert html =~ "Point your IdP at this connection"
      assert html =~ "externalId"

      sync_controls = lv |> element("#directory-sync-#{provider.id}") |> render()
      assert has_element?(lv, "#rotate-scim-#{provider.id}")
      assert has_element?(lv, "#disable-scim-#{provider.id}")
      assert sync_controls =~ "Rotate token"
      assert sync_controls =~ "Disable"
      assert sync_controls =~ "first-child]:mb-0"
      refute sync_controls =~ "Enabled"

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

      {_deleted, _} =
        Emisar.Billing.Subscription.Query.all()
        |> Emisar.Billing.Subscription.Query.by_account_id(account.id)
        |> Repo.delete_all()

      refute Emisar.Billing.sso_available?(account)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Disable directory sync"
      refute html =~ "Turn off directory sync"
      assert has_element?(lv, "#disable-scim-#{provider.id}")

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
      google = insert_provider(account, %{name: "Acme Google", kind: :google_workspace})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{google.id}")

      assert html =~ "isn&#39;t available for Google Workspace"
      assert html =~ "Members are added when they first"
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

    test "lists the provisioned member and suspends them from the connection page", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Synced members"
      assert html =~ "Dana Sync"
      refute Emisar.Accounts.Membership.disabled?(membership)

      render_click(lv, "suspend_member", %{"membership_id" => membership.id})

      assert Emisar.Accounts.Membership.disabled?(Repo.reload!(membership))
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

      assert has_element?(lv, "#{trigger} button[disabled]", "Reactivate")

      assert has_element?(
               lv,
               "#{trigger} [role='tooltip']",
               "Reactivate them there"
             )

      refute has_element?(lv, "#{trigger} button[phx-click]")
    end

    test "a connection with nobody provisioned keeps the confident empty copy", %{
      conn: conn,
      account: account
    } do
      unsynced = insert_provider(account, %{name: "Unsynced Entra", kind: :entra})

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{unsynced.id}")

      assert html =~ "No one has been provisioned through this connection yet"
      refute html =~ "Synced members couldn&#39;t be loaded"
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

      assert html =~ "Synced members couldn&#39;t be loaded"

      assert html =~
               "Refresh the page to try again. This connection may still have provisioned members."

      refute html =~ "No one has been provisioned"
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

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~
               "Role is managed by directory sync — change this member&#39;s groups in your IdP"

      refute html =~ "Role mapping above"
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

    test "creates, lists, and deletes a role mapping", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      # The add form is behind the "Add mapping" button — hidden until clicked.
      refute has_element?(lv, "#create-mapping-#{provider.id}")
      render_click(lv, "add_mapping_form", %{})
      assert has_element?(lv, "#create-mapping-#{provider.id}")

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

      assert html =~ "Role mapping added."
      # The row renders with its display + role.
      assert html =~ "Admins"
      assert html =~ "00g-admins"

      {:ok, [mapping], _meta} = SSO.list_group_mappings(provider, owner)

      # Delete it — the gated event removes the row.
      deleted = render_click(lv, "delete_mapping", %{"id" => mapping.id})
      assert deleted =~ "Role mapping deleted."

      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, owner)
    end

    test "role and runner-access mapping lists page independently and recover stale pages", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      for n <- 1..21 do
        suffix = n |> Integer.to_string() |> String.pad_leading(2, "0")

        {:ok, _mapping} =
          SSO.create_group_mapping(
            provider,
            %{
              external_group_id: "role-group-#{suffix}",
              external_group_display: "Role group #{suffix}",
              role: :operator
            },
            owner
          )

        {:ok, _mapping} =
          SSO.create_group_runner_access_mapping(
            provider,
            %{
              external_group_id: "access-group-#{suffix}",
              external_group_display: "Access group #{suffix}",
              runner_access_mode: :all
            },
            owner
          )
      end

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "#role-mappings-#{provider.id}-pager", "20 / 21 total")

      assert has_element?(
               lv,
               "#runner-access-mappings-#{provider.id}-pager",
               "20 / 21 total"
             )

      assert html =~ "Role group 01"
      refute html =~ "Role group 21"
      assert html =~ "Access group 01"
      refute html =~ "Access group 21"

      _html =
        lv
        |> element("#role-mappings-#{provider.id}-pager a", "Next →")
        |> render_click()

      assert has_element?(lv, "#role-mappings-#{provider.id}-pager", "1 / 21")
      assert render(lv) =~ "Role group 21"
      refute render(lv) =~ "Access group 21"

      _html =
        lv
        |> element("#runner-access-mappings-#{provider.id}-pager a", "Next →")
        |> render_click()

      html = render(lv)
      assert html =~ "Role group 21"
      assert html =~ "Access group 21"

      {:ok, role_mappings, _meta} =
        SSO.list_group_mappings(provider, owner, page: [limit: 100])

      role_21 = Enum.find(role_mappings, &(&1.external_group_id == "role-group-21"))
      html = render_click(lv, "delete_mapping", %{"id" => role_21.id})

      assert has_element?(
               lv,
               "#role-mappings-#{provider.id}-pager a",
               "Back to first page"
             )

      refute html =~ "No role mappings yet."
      assert html =~ "Access group 21"

      _html =
        lv
        |> element("#role-mappings-#{provider.id}-pager a", "Back to first page")
        |> render_click()

      html = render(lv)
      assert html =~ "Role group 01"
      assert html =~ "Access group 21"

      {:ok, runner_mappings, _meta} =
        SSO.list_group_runner_access_mappings(provider, owner, page: [limit: 100])

      runner_21 =
        Enum.find(runner_mappings, &(&1.external_group_id == "access-group-21"))

      html = render_click(lv, "delete_runner_access_mapping", %{"id" => runner_21.id})

      assert has_element?(
               lv,
               "#runner-access-mappings-#{provider.id}-pager a",
               "Back to first page"
             )

      refute html =~ "No IdP groups grant additional runner access."
      assert html =~ "Role group 01"
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

      assert html =~ "Role mapping updated."

      {:ok, [updated], _meta} = SSO.list_group_mappings(provider, owner)
      assert updated.id == mapping.id
      # The externalId (immutable key) is unchanged; display + role applied.
      assert updated.external_group_id == "00g-eng"
      assert updated.external_group_display == "Engineering"
      assert updated.role == :admin
    end

    test "creates, updates, and deletes an independent group runner-access mapping", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner,
      user: user
    } do
      membership = Fixtures.Memberships.fetch_membership(account.id, user.id)
      Fixtures.Memberships.force_runner_access(membership, Emisar.Accounts.RunnerAccess.all())
      runner = Fixtures.Runners.create_runner(account_id: account.id, group: "database")
      assert {:ok, [%{id: runner_id}]} = Emisar.Runners.list_all_runners_for_account(owner)
      assert runner_id == runner.id
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Runner access mapping"

      assert has_element?(
               lv,
               "#runner-access-mapping-section-#{provider.id} > #runner-access-mapping-section-#{provider.id}-help",
               "Each mapping adds runner and pack access"
             )

      refute html =~ "No runners registered yet"
      render_click(lv, "add_runner_access_mapping_form", %{})

      changed =
        lv
        |> form("#create-runner-access-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "runner_access_mapping" => %{"runner_access_mode" => "restricted"}
        })
        |> render_change()

      refute changed =~ "Choose all runners or at least one selected runner scope."

      invalid =
        lv
        |> form("#create-runner-access-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "runner_access_mapping" => %{
            "external_group_id" => "grp-database",
            "runner_access_mode" => "restricted"
          }
        })
        |> render_submit()

      assert invalid =~ "Choose all runners or at least one selected runner scope."

      html =
        lv
        |> form("#create-runner-access-mapping-#{provider.id}", %{
          "provider_id" => provider.id,
          "runner_access_mapping" => %{
            "external_group_id" => "grp-database",
            "external_group_display" => "Database team",
            "runner_access_mode" => "restricted",
            "scope" => ["group:database"]
          }
        })
        |> render_submit()

      assert html =~ "Group runner access added."
      assert html =~ "Database team"
      assert html =~ "database"

      assert {:ok, [mapping], _meta} =
               SSO.list_group_runner_access_mappings(provider, owner)

      mapping_facts =
        lv
        |> element("#runner-access-mapping-facts-#{mapping.id}")
        |> render()

      assert mapping_facts =~ "runners:"
      assert mapping_facts =~ "packs:"
      refute mapping_facts =~ "Selected runners"
      refute mapping_facts =~ "Selected packs"

      render_click(lv, "start_edit_runner_access_mapping", %{"id" => mapping.id})

      updated =
        lv
        |> form("#edit-runner-access-mapping-#{mapping.id}", %{
          "runner_access_mapping_id" => mapping.id,
          "runner_access_mapping" => %{
            "external_group_display" => "Database team",
            "runner_access_mode" => "all"
          }
        })
        |> render_submit()

      assert updated =~ "Group runner access updated."

      assert {:ok, [%{runner_access_mode: :all}], _meta} =
               SSO.list_group_runner_access_mappings(provider, owner)

      deleted = render_click(lv, "delete_runner_access_mapping", %{"id" => mapping.id})
      assert deleted =~ "Group runner access deleted."
      assert {:ok, [], _meta} = SSO.list_group_runner_access_mappings(provider, owner)
    end

    test "a mapped runner scope names the live runner and carries its full id", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r20", group: "database")

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            "external_group_id" => "grp-database",
            "external_group_display" => "Database team",
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          },
          owner
        )

      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "span[title='#{runner.id}']", "r20")
    end

    test "a mapped runner scope that no longer resolves reads as a removed runner", %{
      conn: conn,
      account: account,
      provider: provider,
      owner: owner
    } do
      runner =
        Fixtures.Runners.create_runner(account_id: account.id, name: "r21", group: "database")

      {:ok, _mapping} =
        SSO.create_group_runner_access_mapping(
          provider,
          %{
            "external_group_id" => "grp-database",
            "external_group_display" => "Database team",
            "runner_access_mode" => "restricted",
            "scope" => ["runner:#{runner.id}"]
          },
          owner
        )

      # The mapping outlives the runner row; the chip stays honest instead of
      # printing an unreadable id prefix.
      {:ok, _deleted} = Emisar.Runners.delete_runner(runner, owner)

      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, "span[title='#{runner.id}']", "Removed runner")
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
          "mapping" => %{"external_group_id" => "grp-owner", "role" => "owner"}
        })

      assert rejected =~ "directory sync cannot grant owner"
      assert {:ok, [], _meta} = SSO.list_group_mappings(provider, owner)
    end

    test "a non-admin viewer cannot create a role mapping", %{
      conn: conn,
      account: account,
      user: user,
      provider: provider,
      owner: owner
    } do
      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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
      {:ok, mapping} =
        SSO.create_group_mapping(
          provider,
          %{"external_group_id" => "00g-keep", "role" => "operator"},
          owner
        )

      _ = make_viewer(user)
      {:ok, lv, _html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

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

      assert html =~ "SCIM directory sync"
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

      assert html =~ "Single sign-on needs an owner or admin role."
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

    test "the role picker is the shared select, wired per member", %{
      conn: conn,
      account: account,
      provider: provider,
      membership: membership
    } do
      # No directory sync on this provider, so the row offers the editable picker —
      # through the shared select, not a hand-rolled box: an id per row (one derived
      # id would collide across members), every role offered, the compact
      # form-field metrics, and the chevron room every console select reserves.
      # Whether the change lands is the domain's call, guarded above.
      {:ok, lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert has_element?(lv, ~s(select#synced-role-select-#{membership.id}[name="role"]))

      assert has_element?(
               lv,
               ~s(form#synced-role-#{membership.id}[phx-change="change_member_role"])
             )

      assert has_element?(
               lv,
               ~s(form#synced-role-#{membership.id} input[name="membership_id"][value="#{membership.id}"])
             )

      for role <- Emisar.Auth.roles() do
        assert has_element?(lv, ~s(select[name="role"] option[value="#{role}"]))
      end

      class = select_class(html, "role")
      assert class =~ "pr-8"
      assert class =~ "leading-5"
      assert class =~ "bg-zinc-900"
    end
  end

  # The box classes of a named select — attribute order varies, so anchor on the
  # name with a lookahead.
  defp select_class(html, name) do
    pattern = ~r/<select(?=[^>]*\bname="#{Regex.escape(name)}")[^>]*\bclass="([^"]*)"/

    [_tag, class] = Regex.run(pattern, html)
    class
  end

  describe "the 'point your IdP at this connection' setup steps hide once synced" do
    setup %{conn: conn} do
      {conn, _user, account} = register_and_log_in(conn, %{account: %{plan: "enterprise"}})
      provider = insert_provider(account, %{})
      {:ok, provider} = provider |> Ecto.Changeset.change(scim_enabled: true) |> Repo.update()
      %{conn: conn, account: account, provider: provider}
    end

    test "shown while the directory hasn't synced yet", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      assert html =~ "Point your IdP at this connection"
    end

    test "hidden once the directory synced within the last day", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      {:ok, provider} =
        provider |> Ecto.Changeset.change(scim_last_seen_at: DateTime.utc_now()) |> Repo.update()

      {:ok, _lv, html} = live(conn, ~p"/app/#{account}/settings/sso/#{provider.id}")

      refute html =~ "Point your IdP at this connection"
    end
  end
end

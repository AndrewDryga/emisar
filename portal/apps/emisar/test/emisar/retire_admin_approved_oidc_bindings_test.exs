defmodule Emisar.RetireAdminApprovedOidcBindingsTest do
  use Emisar.DataCase, async: true
  alias Emisar.{Auth, Fixtures, Repo}

  test "the forward repair normalizes legacy rebinds and retires only foreign-active authority" do
    account = Fixtures.Accounts.create_account()
    elsewhere = Fixtures.Accounts.create_account()
    provider = Fixtures.SSO.create_identity_provider(account_id: account.id)

    safe = legacy_rebound_identity(provider, account, "safe")
    Fixtures.Memberships.create_membership(account_id: account.id, user_id: safe.user_id)

    unsafe = legacy_rebound_identity(provider, account, "unsafe")
    activate_in_both_accounts(unsafe.user_id, account.id, elsewhere.id)

    spaced =
      directory_identity(provider, account, "spaced", %{
        provider_identifier: " approved with spaces ",
        scim_external_id: "directory-spaced",
        claims: %{"sub" => " approved with spaces "}
      })

    activate_in_both_accounts(spaced.user_id, account.id, elsewhere.id)

    ordinary =
      directory_identity(provider, account, "ordinary", %{
        provider_identifier: "ordinary",
        scim_external_id: "ordinary",
        claims: %{"sub" => "ordinary"}
      })

    activate_in_both_accounts(ordinary.user_id, account.id, elsewhere.id)

    oidc_first_with_scim_link =
      directory_identity(provider, account, "oidc-linked", %{
        provider_identifier: "oidc-authority",
        scim_external_id: "directory-link",
        claims: %{"sub" => "oidc-authority"},
        created_by: :provider,
        provisioned_via: :oidc_jit
      })

    activate_in_both_accounts(oidc_first_with_scim_link.user_id, account.id, elsewhere.id)

    removed =
      directory_identity(provider, account, "manual", %{
        provider_identifier: "manual-approved",
        created_by: :admin,
        provisioned_via: :manual
      })

    activate_in_both_accounts(removed.user_id, account.id, elsewhere.id)

    dormant = legacy_rebound_identity(provider, account, "dormant")
    Fixtures.Memberships.create_membership(account_id: account.id, user_id: dormant.user_id)

    dormant_foreign =
      Fixtures.Memberships.create_membership(
        account_id: elsewhere.id,
        user_id: dormant.user_id
      )

    Fixtures.Memberships.suspend_membership(dormant_foreign)

    unsafe_token = identity_session(unsafe)
    ordinary_token = identity_session(ordinary)
    removed_token = identity_session(removed)

    migration = Emisar.Repo.Migrations.RetireAdminApprovedOidcBindings

    unless Code.ensure_loaded?(migration) do
      Code.require_file(
        Path.expand(
          "../../priv/repo/migrations/20260930000000_retire_admin_approved_oidc_bindings.exs",
          __DIR__
        )
      )
    end

    normalize_legacy_sql = Function.capture(migration, :normalize_legacy_sql, 0)
    retire_sql = Function.capture(migration, :retire_sql, 0)
    Repo.query!(normalize_legacy_sql.())
    Repo.query!(retire_sql.())

    normalized_safe = Repo.reload!(safe)
    assert normalized_safe.created_by == :admin
    refute normalized_safe.provider_identifier_retired_at

    normalized_dormant = Repo.reload!(dormant)
    assert normalized_dormant.created_by == :admin
    refute normalized_dormant.provider_identifier_retired_at

    retired = Repo.reload!(unsafe)
    assert retired.created_by == :admin
    assert retired.provider_identifier_retired_at
    refute retired.deleted_at
    assert retired.scim_external_id == unsafe.scim_external_id
    assert Auth.fetch_user_and_token_by_session_token(unsafe_token) == {:error, :not_found}

    assert Repo.reload!(spaced).provider_identifier_retired_at

    unchanged = Repo.reload!(ordinary)
    assert unchanged.created_by == :provider
    refute unchanged.provider_identifier_retired_at
    refute unchanged.deleted_at
    assert {:ok, _user, _session} = Auth.fetch_user_and_token_by_session_token(ordinary_token)

    oidc_linked = Repo.reload!(oidc_first_with_scim_link)
    assert oidc_linked.created_by == :provider
    refute oidc_linked.provider_identifier_retired_at
    refute oidc_linked.deleted_at

    assert Repo.reload!(removed).deleted_at
    assert Auth.fetch_user_and_token_by_session_token(removed_token) == {:error, :not_found}
  end

  defp legacy_rebound_identity(provider, account, suffix) do
    directory_identity(provider, account, suffix, %{
      provider_identifier: "approved-#{suffix}",
      scim_external_id: "directory-#{suffix}",
      claims: %{"sub" => "approved-#{suffix}"}
    })
  end

  defp directory_identity(provider, account, suffix, attrs) do
    user = Fixtures.Users.create_user(email: "migration-#{suffix}@example.test")

    Fixtures.SSO.create_user_identity(
      Map.merge(
        %{
          account_id: account.id,
          provider_id: provider.id,
          user_id: user.id,
          created_by: :provider,
          provisioned_via: :scim
        },
        attrs
      )
    )
  end

  defp activate_in_both_accounts(user_id, account_id, elsewhere_id) do
    Fixtures.Memberships.create_membership(account_id: account_id, user_id: user_id)
    Fixtures.Memberships.create_membership(account_id: elsewhere_id, user_id: user_id)
  end

  defp identity_session(identity) do
    {:ok, user} = Emisar.Users.fetch_user_by_id(identity.user_id)

    Fixtures.Auth.create_session_token!(user, :sso, nil, %{}, user_identity_id: identity.id)
  end
end

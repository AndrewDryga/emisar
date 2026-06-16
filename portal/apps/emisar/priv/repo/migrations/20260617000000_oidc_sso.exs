defmodule Emisar.Repo.Migrations.OidcSso do
  use Ecto.Migration

  # OIDC SSO (relying party) + JIT provisioning + auth-identity provenance.
  # Corrective on shipped tables (prod ran 20260520000001), so up/down rather
  # than edit-the-original (IL-11 caveat).

  def up do
    # An SSO-provisioned user is bound by (provider, sub) and may have no
    # email claim — `users.email` must be nullable. The partial unique index
    # then ranges over non-null, live emails only so many nil-email SSO users
    # coexist and password lookups stay unambiguous.
    alter table(:users) do
      modify :email, :citext, null: true
    end

    drop_if_exists index(:users, [:email])
    create unique_index(:users, [:email], where: "email IS NOT NULL AND deleted_at IS NULL")

    # Per-account IdP connection. `client_secret` is stored plaintext (like
    # `users.mfa_secret`) — emisar's at-rest protection is infra-level.
    create table(:identity_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :provisioner, :string, null: false, default: "jit"
      add :name, :string, null: false
      add :issuer, :string, null: false
      add :client_id, :string, null: false
      add :client_secret, :binary
      add :identifier_claim, :string, null: false, default: "sub"
      add :default_role, :string, null: false, default: "viewer"
      add :satisfies_mfa, :boolean, null: false, default: true
      add :allowed_email_domain, :citext
      add :enabled, :boolean, null: false, default: false

      # Directory sync (inbound SCIM 2.0). The per-provider bearer token is
      # 1:1 with the connection (SCIM is one client per IdP), so it lives on
      # the provider row — same prefix+hash shape as every emisar credential.
      add :scim_enabled, :boolean, null: false, default: false
      add :scim_token_prefix, :string
      add :scim_token_hash, :binary

      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:identity_providers, [:account_id])

    # The SCIM bearer resolves a live provider by its lookup prefix — unique
    # among live, scim-bearing providers (mirrors the api-key prefix lookup).
    create unique_index(:identity_providers, [:scim_token_prefix],
             where: "scim_token_prefix IS NOT NULL AND deleted_at IS NULL",
             name: :identity_providers_scim_token_prefix_index
           )

    # One live, enabled provider per (account, kind)…
    create unique_index(:identity_providers, [:account_id, :kind],
             where: "enabled AND deleted_at IS NULL",
             name: :identity_providers_account_kind_enabled_index
           )

    # …and an email domain routes to exactly one account's IdP (sign-in
    # discovery), so it is globally unique among live, enabled providers.
    create unique_index(:identity_providers, [:allowed_email_domain],
             where: "enabled AND deleted_at IS NULL AND allowed_email_domain IS NOT NULL",
             name: :identity_providers_allowed_email_domain_enabled_index
           )

    # Binds an external identity to a user. `provider_identifier` is the OIDC
    # `sub`; the (provider, sub) tuple is the only stable key — never email.
    # `claims` keeps identity + forensic claims (sub/email/name/hd/amr/acr/
    # auth_time); never the IdP's OAuth tokens.
    create table(:user_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id, references(:identity_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :provider_identifier, :string, null: false
      add :claims, :map, null: false, default: %{}
      add :created_by, :string, null: false

      # How this identity was provisioned and its SCIM lifecycle state. The
      # IdP's SCIM `externalId`; when identifier-matching is configured it
      # equals `provider_identifier`, but storing both keeps reconciliation
      # explicit (decision 4). `scim_active` is the SCIM lifecycle flag,
      # distinct from the membership's `disabled_at`.
      add :scim_external_id, :string
      add :provisioned_via, :string
      add :scim_active, :boolean, null: false, default: true

      add :last_seen_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_identities, [:account_id, :provider_id, :provider_identifier],
             where: "deleted_at IS NULL",
             name: :user_identities_provider_identifier_index
           )

    create unique_index(:user_identities, [:account_id, :provider_id, :scim_external_id],
             where: "scim_external_id IS NOT NULL AND deleted_at IS NULL",
             name: :user_identities_scim_external_id_index
           )

    create index(:user_identities, [:user_id])
    create index(:user_identities, [:provider_id])

    # Directory sync (Slice 2b) — IdP groups → emisar role. A server-side
    # mapping of the IdP's `externalId` for a group to an emisar role; sync
    # recomputes a member's role as the HIGHEST mapped role over their synced
    # groups. The role is validated non-`:owner` in the changeset — sync can
    # never grant owner (decision 7).
    create table(:directory_group_role_mappings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id, references(:identity_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :external_group_id, :string, null: false
      add :external_group_display, :string
      add :role, :string, null: false

      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:directory_group_role_mappings, [:provider_id, :external_group_id],
             where: "deleted_at IS NULL",
             name: :directory_group_role_mappings_provider_group_index
           )

    # The synced membership of an IdP group: which provisioned identities
    # belong to which `externalId` group, so a member's role = highest mapped
    # role over the union of their groups. Replaced wholesale on each group
    # sync (PUT) and patched by `add`/`remove` member ops (PATCH).
    create table(:directory_group_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id, references(:identity_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :external_group_id, :string, null: false

      add :user_identity_id,
          references(:user_identities, type: :binary_id, on_delete: :delete_all),
          null: false

      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :directory_group_members,
             [:provider_id, :external_group_id, :user_identity_id],
             where: "deleted_at IS NULL",
             name: :directory_group_members_membership_index
           )

    create index(:directory_group_members, [:provider_id, :external_group_id])
    create index(:directory_group_members, [:user_identity_id])

    # Pending manual-link requests. When a `:manual`-provisioner connection
    # refuses an unknown identity at sign-in, the attempt is captured here (the
    # real OIDC `sub` + the claims, so an admin can recognize the person) and an
    # admin approves it — the binding is always on the captured `sub`, never the
    # email (H1). Resolved requests are hard-deleted (transient by design).
    create table(:sso_link_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_id, references(:identity_providers, type: :binary_id, on_delete: :delete_all),
        null: false

      add :provider_identifier, :string, null: false
      add :email, :string
      add :full_name, :string
      add :claims, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # One pending request per (provider, sub): a re-attempt upserts (refreshes
    # claims + timestamp) instead of piling up duplicate rows.
    create unique_index(:sso_link_requests, [:provider_id, :provider_identifier],
             name: :sso_link_requests_provider_identifier_index
           )

    create index(:sso_link_requests, [:account_id])

    # How a session was authenticated, carried onto the Subject + every audit
    # row (provenance). `auth_method` is the method (password / magic_link /
    # sso); `mfa` records whether a second factor was verified this session —
    # the two are kept separate so "SSO + enforced TOTP" is expressible.
    # `user_identity_id` is set for `:sso`.
    alter table(:user_tokens) do
      add :auth_method, :string
      add :mfa, :boolean, null: false, default: false

      add :user_identity_id,
          references(:user_identities, type: :binary_id, on_delete: :nilify_all)
    end

    # Audit references are loose ids (append-only; survive deletes), so no FK.
    # `mfa` is nullable — a system/API-key/runner event has no session factor.
    alter table(:audit_events) do
      add :auth_method, :string
      add :mfa, :boolean
      add :user_identity_id, :binary_id
    end
  end

  def down do
    alter table(:audit_events) do
      remove :user_identity_id
      remove :mfa
      remove :auth_method
    end

    alter table(:user_tokens) do
      remove :user_identity_id
      remove :mfa
      remove :auth_method
    end

    drop table(:sso_link_requests)
    drop table(:directory_group_members)
    drop table(:directory_group_role_mappings)
    drop table(:user_identities)
    drop table(:identity_providers)

    drop_if_exists index(:users, [:email])
    create unique_index(:users, [:email], where: "deleted_at IS NULL")

    # NB: this raises if any SSO login provisioned a user with no email claim —
    # a column can't return to NOT NULL while NULLs exist. Roll those users
    # forward (set/clear their email) before rolling this migration back.
    alter table(:users) do
      modify :email, :citext, null: false
    end
  end
end

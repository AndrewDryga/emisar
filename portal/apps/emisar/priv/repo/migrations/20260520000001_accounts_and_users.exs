defmodule Emisar.Repo.Migrations.AccountsAndUsers do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "DROP EXTENSION IF EXISTS citext"
    execute "CREATE EXTENSION IF NOT EXISTS \"pgcrypto\"", "DROP EXTENSION IF EXISTS \"pgcrypto\""

    # An account is the multi-tenant boundary. Every other top-level
    # resource (agents, runbooks, policies, audit events) belongs to
    # exactly one account. We use the term "account" rather than
    # "organization" to mirror billing terminology — there is one
    # subscription per account.
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :citext, null: false
      add :paddle_customer_id, :string
      add :require_mfa, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accounts, [:slug])
    create index(:accounts, [:paddle_customer_id])

    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :full_name, :string
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime_usec
      add :mfa_secret, :binary
      add :mfa_enabled_at, :utc_datetime_usec
      add :last_sign_in_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    # NB: we used to call this column `name` but renamed during pre-launch
    # before any production data existed. If you migrated an earlier
    # revision and have a `users.name` column, add a one-off migration
    # to rename it to `full_name`.

    create unique_index(:users, [:email])

    # A user belongs to one or more accounts. Roles inside an account:
    #   :owner    — billing + delete account
    #   :admin    — manage agents, policies, members
    #   :operator — invoke actions, approve runs
    #   :viewer   — read-only access to dashboards + audit
    create table(:memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "operator"
      add :invited_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :invitation_token, :string
      add :invitation_accepted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memberships, [:account_id, :user_id])
    create index(:memberships, [:user_id])
    create index(:memberships, [:invitation_token])

    # Long-lived + ephemeral user tokens: sessions, magic links,
    # password reset, email confirmation. Modeled after Phoenix's
    # generated auth scheme but with explicit `context` so we can grow
    # additional token types without new tables.
    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:user_tokens, [:context, :token])
    create index(:user_tokens, [:user_id, :context])
  end
end

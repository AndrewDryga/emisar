defmodule Emisar.Repo.Migrations.DropPersonalLogins do
  use Ecto.Migration

  # The personal login (`users`) has one reader left: the audit log, whose rows
  # from before Members owned identity name a login ("user"). Many of them stored
  # no name, because the console looked one up when it rendered the row: the
  # login's live Member in the row's own workspace, else the latest name that
  # workspace's trail recorded for the same identity on the same side (a SCIM
  # rename names its target through the payload). Each empty name is stored
  # first, exactly as the console shows it today, so those rows keep their names
  # when the login and its link from the Member go. A row the console cannot
  # name stays empty, and a stored name is never rewritten.
  def up do
    execute(store_empty_names("actor", "NULLIF(BTRIM(h.actor_label), '')"))

    execute(
      store_empty_names("target", """
      COALESCE(
        NULLIF(BTRIM(h.target_label), ''),
        CASE WHEN h.event_type = 'membership.renamed_via_scim'
          THEN NULLIF(BTRIM(h.payload->>'to'), '') END
      )
      """)
    )

    drop index(:account_memberships, [:account_id, :user_id, :updated_at],
           name: :account_memberships_active_owner_contact_idx
         )

    drop index(:account_memberships, [:account_id, :user_id])
    drop index(:account_memberships, [:user_id])

    alter table(:account_memberships) do
      remove :user_id
    end

    # The billing contact is the workspace's earliest active owner, so the
    # owner-contact index now leads with the order that lookup reads.
    create index(:account_memberships, [:account_id, :inserted_at, :id],
             where: "deleted_at IS NULL AND disabled_at IS NULL AND role = 'owner'",
             name: :account_memberships_active_owner_contact_idx
           )

    drop table(:users)
  end

  # Structure only: no login comes back, so the restored link is empty, and the
  # names stored above stay on their rows.
  def down do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext
      add :full_name, :string
      add :confirmed_at, :utc_datetime_usec
      add :mfa_secret, :binary
      add :mfa_enabled_at, :utc_datetime_usec
      add :mfa_last_used_at, :utc_datetime_usec
      add :mfa_recovery_codes, {:array, :binary}, default: []
      add :last_sign_in_at, :utc_datetime_usec
      add :email_changed_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL AND deleted_at IS NULL")

    drop index(:account_memberships, [:account_id, :inserted_at, :id],
           name: :account_memberships_active_owner_contact_idx
         )

    alter table(:account_memberships) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    create unique_index(:account_memberships, [:account_id, :user_id],
             where: "deleted_at IS NULL"
           )

    create index(:account_memberships, [:user_id])

    create index(:account_memberships, [:account_id, :user_id, :updated_at],
             where: "deleted_at IS NULL AND disabled_at IS NULL AND role = 'owner'",
             name: :account_memberships_active_owner_contact_idx
           )
  end

  # One statement per side. Each identity with an empty name is resolved once:
  # its live Member's name (a nonblank display name, else the address), else the
  # latest snapshot (newest first, the id breaking a tie). A Member that resolves
  # to no name falls through to the history, as the console's does. A
  # whitespace-only stored name is shown as stored unless a live Member names it,
  # so only that case replaces one. LEFT keeps a payload-derived name inside the
  # column's 255 characters; a Member's name and address always fit.
  defp store_empty_names(side, snapshot) do
    """
    WITH identities AS (
      SELECT DISTINCT account_id, #{side}_id AS id
      FROM audit_events
      WHERE #{side}_kind = 'user' AND #{side}_id IS NOT NULL
        AND (#{side}_label IS NULL OR BTRIM(#{side}_label) = '')
    ),
    names AS (
      SELECT i.account_id, i.id, live.label IS NOT NULL AS live,
        CASE WHEN live.label IS NOT NULL THEN NULLIF(live.label, '') ELSE latest.label END
          AS label
      FROM identities i
      LEFT JOIN LATERAL (
        SELECT COALESCE(NULLIF(BTRIM(m.display_name), ''), m.email::text) AS label
        FROM account_memberships m
        WHERE m.account_id = i.account_id AND m.user_id = i.id AND m.deleted_at IS NULL
      ) live ON true
      LEFT JOIN LATERAL (
        SELECT snapshot.label
        FROM (
          SELECT #{snapshot} AS label, h.occurred_at, h.id
          FROM audit_events h
          WHERE h.account_id = i.account_id AND h.#{side}_kind = 'user' AND h.#{side}_id = i.id
        ) snapshot
        WHERE snapshot.label IS NOT NULL
        ORDER BY snapshot.occurred_at DESC, snapshot.id DESC
        LIMIT 1
      ) latest ON true
    )
    UPDATE audit_events e
    SET #{side}_label = LEFT(n.label, 255)
    FROM names n
    WHERE e.account_id = n.account_id AND e.#{side}_kind = 'user' AND e.#{side}_id = n.id
      AND n.label IS NOT NULL
      AND (e.#{side}_label IS NULL OR e.#{side}_label = '' OR (n.live AND BTRIM(e.#{side}_label) = ''))
    """
  end
end

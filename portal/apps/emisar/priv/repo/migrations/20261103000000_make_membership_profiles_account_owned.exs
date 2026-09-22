defmodule Emisar.Repo.Migrations.MakeMembershipProfilesAccountOwned do
  use Ecto.Migration

  def up do
    rename table(:account_memberships), :directory_display_name, to: :display_name

    alter table(:account_memberships) do
      add :contact_email, :citext
      add :contact_generation, :bigint, null: false, default: 0
    end

    create constraint(:account_memberships, :contact_generation_nonnegative,
             check: "contact_generation >= 0"
           )

    # A directory's old name override and unambiguous claims are local facts.
    # Its shared User may since have changed privately: never use that row as
    # the fallback for a directory member. Unknown historical contacts remain
    # absent until independently established, not silently disclosed or proved.
    # Ordinary personal memberships snapshot their already-linked profile;
    # an outstanding invitation owns only the address it was actually sent to.
    execute("""
    WITH directory_claims AS (
      SELECT account_id, user_id,
        CASE WHEN jsonb_typeof(claims->'name') = 'string'
          AND char_length(BTRIM(claims->>'name')) BETWEEN 1 AND 255
          THEN BTRIM(claims->>'name') END AS name,
        CASE WHEN jsonb_typeof(claims->'email') = 'string'
          AND octet_length(BTRIM(claims->>'email')) BETWEEN 3 AND 254
          AND BTRIM(claims->>'email') ~ '^[^[:space:]]+@[^[:space:]]+$'
          THEN BTRIM(claims->>'email') END AS email
      FROM sso_user_identities
    ), directory_profiles AS (
      SELECT account_id, user_id,
        CASE WHEN count(DISTINCT name) = 1 THEN max(name) END AS name,
        CASE WHEN count(DISTINCT lower(email)) = 1 THEN max(email) END AS email
      FROM directory_claims
      GROUP BY account_id, user_id
    ), profiles AS (
      SELECT m.id,
        COALESCE(NULLIF(BTRIM(m.display_name), ''), d.name,
          CASE WHEN d.user_id IS NULL AND m.invitation_token_digest IS NULL
            THEN u.full_name END) AS name,
        COALESCE(m.invitation_sent_to, d.email,
          CASE WHEN d.user_id IS NULL AND m.invitation_token_digest IS NULL
            THEN u.email END) AS email
      FROM account_memberships m
      JOIN users u ON u.id = m.user_id
      LEFT JOIN directory_profiles d ON d.account_id = m.account_id AND d.user_id = m.user_id
    )
    UPDATE account_memberships m
    SET display_name = p.name, contact_email = p.email, updated_at = timezone('UTC', now())
    FROM profiles p WHERE p.id = m.id
    """)
  end

  def down do
    drop constraint(:account_memberships, :contact_generation_nonnegative)

    alter table(:account_memberships) do
      remove :contact_generation
      remove :contact_email
    end

    rename table(:account_memberships), :display_name, to: :directory_display_name
  end
end

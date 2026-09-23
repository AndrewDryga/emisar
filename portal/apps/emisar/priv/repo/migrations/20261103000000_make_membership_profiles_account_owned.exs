defmodule Emisar.Repo.Migrations.MakeMembershipProfilesAccountOwned do
  use Ecto.Migration

  def up do
    rename table(:account_memberships), :directory_display_name, to: :display_name

    alter table(:account_memberships) do
      add :contact_email, :citext
    end

    # Snapshot the name and address each workspace already showed as its local
    # profile. An outstanding invitation owns only the address it was sent to.
    execute("""
    UPDATE account_memberships m
    SET display_name = COALESCE(NULLIF(BTRIM(m.display_name), ''),
          CASE WHEN m.invitation_token_digest IS NULL THEN NULLIF(BTRIM(u.full_name), '') END),
        contact_email = COALESCE(m.invitation_sent_to,
          CASE WHEN m.invitation_token_digest IS NULL THEN u.email END),
        updated_at = timezone('UTC', now())
    FROM users u
    WHERE u.id = m.user_id
    """)
  end

  def down do
    alter table(:account_memberships) do
      remove :contact_email
    end

    rename table(:account_memberships), :display_name, to: :directory_display_name
  end
end

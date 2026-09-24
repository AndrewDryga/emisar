defmodule Emisar.Repo.Migrations.BindSSOIdentitiesToMemberships do
  use Ecto.Migration

  # Each user's live seat in the account, else their latest removed one. A
  # removed seat keeps directory history and never authorizes a sign-in. A link
  # request may match a pending invitation, as provisioning does, so its
  # approval still waits for the invitee.
  @seat """
  SELECT DISTINCT ON (account_id, user_id) account_id, user_id, id
  FROM account_memberships
  ORDER BY account_id, user_id, (deleted_at IS NULL) DESC, inserted_at DESC, id DESC
  """

  # An identity never binds to a pending invitation: 20261112 detaches it from
  # this login, and whoever proves the invited address accepts it.
  @identity_seat """
  SELECT DISTINCT ON (account_id, user_id) account_id, user_id, id
  FROM account_memberships
  WHERE NOT (invitation_accepted_at IS NULL AND invitation_token_digest IS NOT NULL)
  ORDER BY account_id, user_id, (deleted_at IS NULL) DESC, inserted_at DESC, id DESC
  """

  def up do
    create unique_index(:account_memberships, [:account_id, :id])

    alter table(:sso_user_identities) do
      add :membership_id, :binary_id
    end

    # A link request may match no Member, so this one stays nullable.
    alter table(:sso_link_requests) do
      add :matched_membership_id, :binary_id
    end

    execute """
    UPDATE sso_user_identities i SET membership_id = seat.id
    FROM (#{@identity_seat}) seat
    WHERE seat.account_id = i.account_id AND seat.user_id = i.user_id
    """

    # Every identity belongs to a seat. An identity whose person has no seat in its
    # workspace fails here, loudly, instead of losing its only person anchor when
    # 20261110 drops user_id.
    execute "ALTER TABLE sso_user_identities ALTER COLUMN membership_id SET NOT NULL"

    execute """
    UPDATE sso_link_requests r SET matched_membership_id = seat.id
    FROM (#{@seat}) seat
    WHERE seat.account_id = r.account_id AND seat.user_id = r.matched_user_id
    """

    execute """
    ALTER TABLE sso_user_identities
    ADD CONSTRAINT sso_user_identities_membership_account_fkey
    FOREIGN KEY (account_id, membership_id)
    REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
    """

    execute """
    ALTER TABLE sso_link_requests
    ADD CONSTRAINT sso_link_requests_membership_account_fkey
    FOREIGN KEY (account_id, matched_membership_id)
    REFERENCES account_memberships (account_id, id) ON DELETE CASCADE
    """

    create index(:sso_user_identities, [:membership_id])
    create index(:sso_link_requests, [:matched_membership_id])
  end

  def down do
    alter table(:sso_link_requests) do
      remove :matched_membership_id
    end

    alter table(:sso_user_identities) do
      remove :membership_id
    end

    drop index(:account_memberships, [:account_id, :id])
  end
end

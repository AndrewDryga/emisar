defmodule Emisar.Repo.Migrations.DetachInvitationsFromPersonalLogins do
  use Ecto.Migration

  # An invitation names an email address, not a personal login: accepting it
  # links whoever proves that address. Outstanding invitations drop the login an
  # earlier build created or matched when inviting; accepted seats keep theirs.
  # With no login bound, nothing compares an invited login's address generation.
  def up do
    execute """
    UPDATE account_memberships
    SET user_id = NULL, updated_at = timezone('UTC', now())
    WHERE invitation_accepted_at IS NULL
      AND invitation_token_digest IS NOT NULL
      AND user_id IS NOT NULL
    """

    alter table(:account_memberships) do
      remove :invitation_email_changed_at
    end
  end

  # The column comes back empty, and the logins outstanding invitations were
  # bound to are not restored. The earlier build then neither accepts nor
  # resends those invitations; an administrator removes and re-invites them.
  def down do
    alter table(:account_memberships) do
      add :invitation_email_changed_at, :utc_datetime_usec
    end
  end
end

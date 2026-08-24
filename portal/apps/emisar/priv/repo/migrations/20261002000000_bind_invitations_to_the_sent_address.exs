defmodule Emisar.Repo.Migrations.BindInvitationsToTheSentAddress do
  @moduledoc """
  Binds new and resent invitation bearers to the exact email generation they
  prove. Historical invitations deliberately retain NULL binding fields: the
  original recipient was not stored, so copying the user's current address
  would risk authorizing an old-inbox link after an address change. Those links
  fail closed until an administrator resends them.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_changed_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    alter table(:account_memberships) do
      add :invitation_sent_to, :citext
      add :invitation_email_changed_at, :utc_datetime_usec
    end
  end
end

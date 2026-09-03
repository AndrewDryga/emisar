defmodule Emisar.Repo.Migrations.PreserveAcceptedInvitationCredentials do
  use Ecto.Migration

  @stage_table "accepted_invitation_memberships_20261019"

  def up do
    execute(fn -> preserve!(repo()) end)
  end

  def down do
    raise "accepted invitation timestamps cannot be hidden independently of the repair migration"
  end

  @doc false
  def preserve!(repo) do
    repo.query!("""
    CREATE TABLE #{@stage_table} AS
    SELECT id AS membership_id, invitation_accepted_at
    FROM account_memberships
    WHERE invitation_accepted_at IS NOT NULL
      AND invitation_token_digest IS NULL
    """)

    repo.query!("""
    UPDATE account_memberships AS membership
    SET invitation_accepted_at = NULL
    FROM #{@stage_table} AS staged
    WHERE membership.id = staged.membership_id
    """)
  end
end

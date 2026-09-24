defmodule Emisar.Repo.Migrations.UnlinkDirectoryCreatedSeats do
  use Ecto.Migration

  # A seat created together with its identity (by OIDC JIT, by SCIM, or by an
  # admin approving an unmatched link request) was bound to whichever personal
  # login matched the address the directory asserted. Unlink those seats, as
  # provisioning now creates them, and drop their session grants. The person
  # keeps workspace SSO and links a personal login again by proving the
  # mailbox. Founding owners, accepted invitations, admin links onto existing
  # seats and self-linked identities stay linked.
  @directory_seats """
  SELECT m.id
  FROM account_memberships m
  JOIN sso_user_identities i ON i.membership_id = m.id
  WHERE m.user_id IS NOT NULL
    AND m.invitation_accepted_at IS NULL
    AND (i.provisioned_via IN ('oidc_jit', 'scim')
      OR (i.provisioned_via = 'manual' AND i.created_by = 'admin'))
    AND abs(extract(epoch FROM (i.inserted_at - m.inserted_at))) < 10
  """

  def up do
    execute "DELETE FROM auth_member_grants WHERE membership_id IN (#{@directory_seats})"

    execute """
    UPDATE account_memberships SET user_id = NULL, updated_at = timezone('UTC', now())
    WHERE id IN (#{@directory_seats})
    """
  end

  # The links are not restored; each person links again by proving the mailbox.
  def down, do: :ok
end

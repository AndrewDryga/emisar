defmodule Emisar.Repo.Migrations.FreeMembershipsStrandedByARemovedDirectory do
  @moduledoc """
  Disabling directory sync — or deleting the connection outright — handed role
  control back to operators but left `directory_suspended` set on anyone the
  directory had deactivated. `reinstate_membership/2` refuses such a row with
  `:deactivated_in_idp`, on the reasoning that only the IdP may lift what the IdP
  placed. With the IdP gone there was nothing left to lift it, and no operator
  could either: the member was suspended permanently, by no one.

  The write path now clears the flag when directory control is removed. This
  frees the rows already stuck, identified by exactly that shape — suspended by a
  directory, with no directory left to answer for it.

  The suspension itself stays. The directory's last word was that this person is
  out; what changes is that a human can now act on it.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE account_memberships
    SET directory_suspended = false, updated_at = now()
    WHERE directory_suspended = true
      AND directory_provider_id IS NULL
    """
  end

  # No down: re-stranding these rows would restore a state nobody can leave.
  def down, do: :ok
end

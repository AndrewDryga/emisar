defmodule Emisar.Repo.Migrations.RevokeMembershipUnboundApiKeys do
  use Ecto.Migration

  # API keys inherit the minting membership's runner scopes. Without that
  # binding, an empty scope set used to mean the entire account fleet. New keys
  # always carry the membership; conservatively revoke any ambiguous historic
  # row rather than inventing an owner from mutable user/account relationships.
  def up do
    execute("""
    UPDATE api_keys
    SET revoked_at = NOW(), updated_at = NOW()
    WHERE created_by_membership_id IS NULL
      AND revoked_at IS NULL
    """)
  end

  # Irreversible: the missing membership cannot be reconstructed reliably, and
  # restoring an unscoped bearer credential would re-open the authorization gap.
  def down, do: :ok
end

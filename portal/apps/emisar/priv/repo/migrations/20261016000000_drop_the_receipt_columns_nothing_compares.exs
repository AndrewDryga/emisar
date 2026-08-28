defmodule Emisar.Repo.Migrations.DropTheReceiptColumnsNothingCompares do
  use Ecto.Migration

  # Two write-only receipts, each shadowing a mechanism that works without it
  # (founder-delegated calls, 2026-08-28):
  #
  # sign_in_verified_identity_id — the one unread column of the provider's
  # four-column verification receipt. Since 20260826 a user holds exactly ONE
  # live identity per provider, so (provider, sign_in_verified_by_user_id)
  # already names the identity, and the audit event records the act.
  #
  # directory_authorization_version — the "applied" half of the SCIM
  # fail-closed pair. The pair's guard runs entirely on the PENDING half:
  # a directory change marks pending, the reconcile job selects on pending,
  # and ensure_current_authorization_version compares pending against the
  # provider. "Authorization is current" is exactly "pending IS NULL"; the
  # applied receipt was written on every sync and compared by nothing.
  def change do
    alter table(:sso_identity_providers) do
      remove :sign_in_verified_identity_id, references(:sso_user_identities, type: :binary_id)
    end

    alter table(:account_memberships) do
      remove :directory_authorization_version, :integer
    end
  end
end

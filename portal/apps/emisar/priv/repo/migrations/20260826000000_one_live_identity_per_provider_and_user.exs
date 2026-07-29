defmodule Emisar.Repo.Migrations.OneLiveIdentityPerProviderAndUser do
  @moduledoc """
  A person has ONE identity per connection. The schema was already built for it —
  `provider_identifier` holds the OIDC `sub` and `scim_external_id` the directory's
  `externalId`, two columns on one row precisely so a login and a directory push
  converge on the same person — but nothing enforced it.

  Without the constraint, approving a link request for a member who already had an
  identity inserted a SECOND one. Role and runner access are then computed per
  identity and written to the same membership, so whichever iteration ran last
  decided the person's privileges. The authorization-reconcile job was worse: it
  reads the identity with `Repo.peek`, which raises on two rows, taking down every
  remaining membership in that batch.

  Existing duplicates are collapsed rather than left to fail the index. The
  survivor is the row the directory addresses (`scim_external_id` present), and
  among equals the earliest — the original binding, not whatever raced in later.
  The rest are soft-deleted, which is how an identity is retired everywhere else.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE sso_user_identities SET deleted_at = now()
    WHERE deleted_at IS NULL
      AND id NOT IN (
        SELECT DISTINCT ON (account_id, provider_id, user_id) id
        FROM sso_user_identities
        WHERE deleted_at IS NULL
        ORDER BY account_id, provider_id, user_id,
                 (scim_external_id IS NOT NULL) DESC, inserted_at ASC, id ASC
      )
    """

    create unique_index(:sso_user_identities, [:account_id, :provider_id, :user_id],
             where: "deleted_at IS NULL",
             name: :sso_user_identities_live_user_index
           )
  end

  def down do
    drop index(:sso_user_identities, [:account_id, :provider_id, :user_id],
           name: :sso_user_identities_live_user_index
         )
  end
end

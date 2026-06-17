defmodule Emisar.Repo.Migrations.AddMatchedUserToSsoLinkRequests do
  use Ecto.Migration

  # Corrective (not edit-original): the table came from 20260617000000_oidc_sso,
  # which is already migrated on prod. A nullable FK — set when the captured
  # email matches an EXISTING account member, so an admin can link the IdP
  # identity to that user instead of failing/duplicating; nilified if the user
  # is later deleted.
  def change do
    alter table(:sso_link_requests) do
      add :matched_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end
  end
end

defmodule Emisar.Repo.Migrations.AddScimLastSeenToIdentityProviders do
  use Ecto.Migration

  # "Is directory sync actually working?" — record the last time the IdP's SCIM
  # connector authenticated against us, so the connection detail page can show a
  # live status ("Last synced 2h ago" vs "No syncs yet"). Nullable; stamped
  # (throttled) on each authenticated SCIM request.
  def change do
    alter table(:identity_providers) do
      add :scim_last_seen_at, :utc_datetime_usec
    end
  end
end

defmodule Emisar.Repo.Migrations.AddOauthClientMetadataUrl do
  use Ecto.Migration

  # A Client ID Metadata Document client identifies itself by the HTTPS URL its
  # metadata is served from rather than a server-minted id. Store that URL so a
  # later authorization or token request resolves the same row instead of
  # materializing a duplicate; DCR registrations leave it null.
  def change do
    alter table(:oauth_clients) do
      add :client_id_metadata_url, :string
    end

    create unique_index(:oauth_clients, [:client_id_metadata_url],
             where: "client_id_metadata_url IS NOT NULL"
           )
  end
end

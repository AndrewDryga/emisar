defmodule Emisar.Repo.Migrations.LinkRequestsRecordTheirNamespace do
  @moduledoc """
  A link request carries an identifier, but not which namespace it came from —
  the OIDC `sub` or the directory's `externalId`. Approval therefore had one
  behaviour for both: it rebound `provider_identifier`. When the two values
  differ, that let the identity be dragged back and forth between them, one
  approval at a time, with whichever namespace was not current unable to find
  the person at all.

  Recording the source is what lets approval stamp the right column.

  `oidc` is the backfill default because the OIDC callback was the original and
  only writer of these rows; the SCIM path captures one solely when an email
  collides, which no production tenant has reached (no SSO or SCIM connection
  exists in production).
  """
  use Ecto.Migration

  def change do
    alter table(:sso_link_requests) do
      add :source, :string, null: false, default: "oidc"
    end

    create constraint(:sso_link_requests, :sso_link_requests_source,
             check: "source IN ('oidc', 'scim')"
           )
  end
end

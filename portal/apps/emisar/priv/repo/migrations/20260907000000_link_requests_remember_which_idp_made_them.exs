defmodule Emisar.Repo.Migrations.LinkRequestsRememberWhichIdpMadeThem do
  @moduledoc """
  Repointing a connection is refused once an identity is bound, so it is allowed
  exactly while none is — which is when pending link requests exist. Deleting
  them alongside the change closes the common case, but not a callback already
  in flight: it verifies a token under the old issuer, pauses, and inserts its
  request after the sweep has run.

  A fingerprint of the namespace that produced the request is what the approval
  can check under the provider lock, whoever wrote the row and whenever.

  Existing rows get none. They are pre-1.0 development rows, and a null reads as
  "cannot be attributed to the current namespace" — which is the safe answer.
  """
  use Ecto.Migration

  def change do
    alter table(:sso_link_requests) do
      add :namespace_fingerprint, :string
    end
  end
end

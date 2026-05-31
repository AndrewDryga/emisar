defmodule Emisar.Catalog.PackVersion.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.PackVersion

  def upsert(attrs) do
    %PackVersion{}
    |> cast(attrs, [:account_id, :pack_id, :version, :hash, :first_seen_at, :last_seen_at])
    |> validate_required([:account_id, :pack_id, :version, :first_seen_at, :last_seen_at])
    |> unique_constraint([:account_id, :pack_id, :version, :hash])
  end
end

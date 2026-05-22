defmodule Emisar.Catalog.PackVersion do
  @moduledoc """
  An observed pack version. Multiple runners may have the same
  (pack_id, version, hash); we only record one row per unique
  combination per account. Drift detection: same pack_id+version with
  different hashes = somebody hand-edited a pack on a host.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pack_versions" do
    field :pack_id, :string
    field :version, :string
    field :hash, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(pack, attrs) do
    pack
    |> cast(attrs, [:account_id, :pack_id, :version, :hash, :first_seen_at, :last_seen_at])
    |> validate_required([:account_id, :pack_id, :version, :first_seen_at, :last_seen_at])
    |> unique_constraint([:account_id, :pack_id, :version, :hash])
  end
end

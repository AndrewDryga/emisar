defmodule Emisar.Catalog.PackVersion do
  @moduledoc """
  An observed pack version. Multiple runners may have the same
  (pack_id, version, hash); we only record one row per unique
  combination per account. Drift detection: same pack_id+version with
  different hashes = somebody hand-edited a pack on a host.
  """

  use Emisar, :schema

  schema "pack_versions" do
    field :pack_id, :string
    field :version, :string
    field :hash, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account

    timestamps()
  end
end

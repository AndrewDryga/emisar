defmodule Emisar do
  @moduledoc """
  Common interface for the domain modules. `use Emisar, :schema`,
  `:query`, or `:changeset` to pull in a consistent set of imports
  and attributes for each role — keeps every schema / query /
  changeset file in the codebase symmetrical.
  """

  def schema do
    quote do
      use Ecto.Schema

      # UUIDv7 — time-ordered IDs that cluster at the index tail
      # instead of thrashing B-trees the way random v4s do. Wire +
      # storage format unchanged from v4 (postgres `uuid` column);
      # only the bit layout inside the binary differs. Monotonic
      # precision guarantees same-ms IDs still sort in generation
      # order (RFC 9562 §6.2).
      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
      @foreign_key_type :binary_id

      @timestamps_opts [type: :utc_datetime_usec]

      @type id :: binary()
    end
  end

  def query do
    quote do
      import Ecto.Query
      @behaviour Emisar.Repo.Query
    end
  end

  def changeset do
    quote do
      import Ecto.Changeset
      import Emisar.Repo.Changeset
      import Emisar.Repo, only: [valid_uuid?: 1]
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

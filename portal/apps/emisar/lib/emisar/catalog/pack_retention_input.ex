defmodule Emisar.Catalog.PackRetentionInput do
  @moduledoc """
  The account's automatic pack-cleanup choice — how many days a pack version
  may go unadvertised before the sweep removes it. Never persisted: `Catalog`
  casts the raw settings form (and the stored setting it later reads back)
  through it, so a malformed or non-positive period is a field error at the
  context boundary instead of an unusable number reaching Accounts or a
  destructive sweep.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # nil = automatic cleanup off (versions are kept forever).
    field :days, :integer
  end

  @fields ~w[days]a

  @doc """
  Casts one set of retention attrs — a string-keyed browser map, or an
  atom-keyed map / keyword list. A blank period means cleanup is off; a
  malformed, zero, or negative one is a field error, never coerced.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(castable(attrs), @fields)
    |> validate_number(:days, greater_than: 0)
  end

  defp castable(attrs) when is_list(attrs), do: Map.new(attrs)
  defp castable(attrs) when is_map(attrs), do: attrs
end

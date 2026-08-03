defmodule Emisar.Runners.InactiveRetentionInput do
  @moduledoc """
  The account's automatic runner-cleanup choice — how many hours a runner may
  stay cleanly offline before the sweep soft-deletes it. Never persisted:
  `Runners` casts the raw settings form (and the stored setting it later reads
  back) through it, so a malformed or non-positive window is a field error at
  the context boundary instead of an unusable number reaching Accounts or a
  destructive sweep.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # nil = automatic cleanup off (inactive runners are kept).
    field :hours, :integer
  end

  @fields ~w[hours]a

  @doc """
  Casts one set of retention attrs — a string-keyed browser map, or an
  atom-keyed map / keyword list. A blank window means cleanup is off; a
  malformed, zero, or negative one is a field error, never coerced.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(castable(attrs), @fields)
    |> validate_number(:hours, greater_than: 0)
  end

  defp castable(attrs) when is_list(attrs), do: Map.new(attrs)
  defp castable(attrs) when is_map(attrs), do: attrs
end

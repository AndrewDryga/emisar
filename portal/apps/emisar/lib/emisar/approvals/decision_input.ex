defmodule Emisar.Approvals.DecisionInput do
  @moduledoc """
  The approver's standing-grant choices on an approve — the reuse window, the
  argument scope, and an optional use cap. Never persisted: `Approvals` casts
  the raw decision form (or a caller's keyword opts) through it, so an
  unrecognized duration or a malformed cap is a field error at the context
  boundary instead of a crash inside grant minting.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Every grant carries an explicit re-confirm horizon; `:once` mints none.
    field :duration, Ecto.Enum,
      values: [:once, :one_hour, :one_day, :thirty_days, :ninety_days],
      default: :once

    field :scope, Ecto.Enum, values: [:exact_args, :any_args], default: :exact_args
    # nil = unlimited within the window.
    field :max_uses, :integer
  end

  @fields ~w[duration scope max_uses]a

  @doc """
  Casts one set of decision attrs — a string-keyed browser map, or an
  atom-keyed map / keyword list. An absent duration or scope falls back to the
  single-use default; an unrecognized one is a field error, never coerced.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(castable(attrs), @fields)
    |> validate_required([:duration, :scope])
    |> validate_number(:max_uses, greater_than: 0)
  end

  defp castable(attrs) when is_list(attrs), do: Map.new(attrs)
  defp castable(attrs) when is_map(attrs), do: attrs
end

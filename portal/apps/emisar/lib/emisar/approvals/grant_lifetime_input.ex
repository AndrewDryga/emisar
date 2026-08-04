defmodule Emisar.Approvals.GrantLifetimeInput do
  @moduledoc """
  The account's standing-grant guardrail — how many seconds an approved grant
  may keep skipping the prompt, where `0` is the kill switch that disables
  standing grants entirely. Never persisted: `Approvals` casts the raw
  guardrails form through it, so a malformed or negative cap is a field error at
  the context boundary instead of an unusable number reaching Accounts or the
  disable sweep.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # nil = no cap · N = grants may live at most N seconds · 0 = standing
    # grants DISABLED (mint + match both refuse; every approval is single-use).
    field :seconds, :integer
  end

  @fields ~w[seconds]a

  @doc """
  Casts one set of cap attrs — a string-keyed browser map, or an atom-keyed map
  / keyword list. A blank cap means no cap at all; a malformed or negative one
  is a field error, never coerced.
  """
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(castable(attrs), @fields)
    |> validate_number(:seconds, greater_than_or_equal_to: 0)
  end

  defp castable(attrs) when is_list(attrs), do: Map.new(attrs)
  defp castable(attrs) when is_map(attrs), do: attrs
end

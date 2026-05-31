defmodule Emisar.Repo.Changeset do
  @moduledoc """
  Reusable `Ecto.Changeset` helpers. Kept intentionally small —
  add to this only when at least two changesets need the same shape.
  """
  import Ecto.Changeset

  @doc """
  Put `field` to `value` only when it's nil or unset. `value` may be
  a literal, a 0-arity function (lazy default), or a 1-arity function
  taking the current changeset.

      put_default_value(cs, :name, "untitled")
      put_default_value(cs, :slug, &generate_slug/0)
      put_default_value(cs, :legal_name, from: :name)
  """
  def put_default_value(%Ecto.Changeset{} = cs, _field, nil), do: cs

  def put_default_value(%Ecto.Changeset{} = cs, field, from: source_field) do
    case fetch_field(cs, source_field) do
      {_data_or_changes, value} -> put_default_value(cs, field, value)
      :error -> cs
    end
  end

  def put_default_value(%Ecto.Changeset{} = cs, field, value) do
    case fetch_field(cs, field) do
      {:data, nil} -> put_change(cs, field, maybe_apply(cs, value))
      :error -> put_change(cs, field, maybe_apply(cs, value))
      _ -> cs
    end
  end

  defp maybe_apply(_cs, fun) when is_function(fun, 0), do: fun.()
  defp maybe_apply(cs, fun) when is_function(fun, 1), do: fun.(cs)
  defp maybe_apply(_cs, value), do: value
end

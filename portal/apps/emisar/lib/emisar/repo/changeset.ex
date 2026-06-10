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

      put_default_value(changeset, :name, "untitled")
      put_default_value(changeset, :slug, &generate_slug/0)
      put_default_value(changeset, :legal_name, from: :name)
  """
  def put_default_value(%Ecto.Changeset{} = changeset, _field, nil), do: changeset

  def put_default_value(%Ecto.Changeset{} = changeset, field, from: source_field) do
    case fetch_field(changeset, source_field) do
      {_data_or_changes, value} -> put_default_value(changeset, field, value)
      :error -> changeset
    end
  end

  def put_default_value(%Ecto.Changeset{} = changeset, field, value) do
    case fetch_field(changeset, field) do
      {:data, nil} -> put_change(changeset, field, maybe_apply(changeset, value))
      :error -> put_change(changeset, field, maybe_apply(changeset, value))
      _ -> changeset
    end
  end

  defp maybe_apply(_changeset, fun) when is_function(fun, 0), do: fun.()
  defp maybe_apply(changeset, fun) when is_function(fun, 1), do: fun.(changeset)
  defp maybe_apply(_changeset, value), do: value

  @doc """
  True when the changeset failed on a `unique_constraint` — for mapping a
  DB-uniqueness violation back to a domain error at the call site
  (e.g. a duplicate membership insert → `{:error, :already_member}`).
  """
  def unique_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end
end

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

  @doc """
  Truncates each field's change to `limit` CODEPOINTS, the unit `varchar(n)`
  counts — for request metadata (IP, user agent) that arrives straight off a
  header and must never fail its insert.

  `String.slice/3` counts graphemes, so slicing to 255 there still lets 255
  combining marks through as 510 codepoints and the insert raises 22001. A
  non-binary change passes through unchanged.
  """
  def truncate_codepoints(%Ecto.Changeset{} = changeset, fields, limit) do
    Enum.reduce(fields, changeset, fn field, acc ->
      update_change(acc, field, &take_codepoints(&1, limit))
    end)
  end

  defp take_codepoints(value, limit) when is_binary(value) do
    value |> String.codepoints() |> Enum.take(limit) |> IO.iodata_to_binary()
  end

  defp take_codepoints(value, _limit), do: value

  @doc """
  Adds an error to `field` when its change serializes to more than `max_bytes`
  of JSON — a DoS guard on `:map`/`:array` columns fed by external input. A field
  left unset, and a value Jason can't encode, both pass through unchanged.
  """
  def validate_json_size(%Ecto.Changeset{} = changeset, field, max_bytes) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Jason.encode(value) do
          {:ok, json} when byte_size(json) > max_bytes ->
            add_error(changeset, field, "is too large (max #{max_bytes} bytes serialized)")

          _ ->
            changeset
        end
    end
  end

  @doc "Adds an error when a decoded JSON field exceeds structural limits."
  def validate_json_structure(%Ecto.Changeset{} = changeset, field, max_depth, max_nodes) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Emisar.JSONValue.validate(value, max_depth: max_depth, max_nodes: max_nodes) do
          :ok -> changeset
          {:error, :too_deep} -> add_error(changeset, field, "is nested too deeply")
          {:error, :too_many_nodes} -> add_error(changeset, field, "has too many values")
          {:error, :invalid_value} -> add_error(changeset, field, "must contain JSON values")
        end
    end
  end

  @doc "Validates structure before serializing a decoded JSON field for its byte bound."
  def validate_json_value(%Ecto.Changeset{} = changeset, field, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    max_depth = Keyword.fetch!(opts, :max_depth)
    max_nodes = Keyword.fetch!(opts, :max_nodes)

    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Emisar.JSONValue.validate(value, max_depth: max_depth, max_nodes: max_nodes) do
          :ok -> validate_json_size(changeset, field, max_bytes)
          {:error, :too_deep} -> add_error(changeset, field, "is nested too deeply")
          {:error, :too_many_nodes} -> add_error(changeset, field, "has too many values")
          {:error, :invalid_value} -> add_error(changeset, field, "must contain JSON values")
        end
    end
  end
end

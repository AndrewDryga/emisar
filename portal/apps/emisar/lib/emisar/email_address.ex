defmodule Emisar.EmailAddress do
  @moduledoc """
  One shape check for an operator-entered email address.

  Every changeset that takes an address uses this one check, capped at 254
  bytes, RFC 5321's maximum (both columns are `citext`).

  Deliberately a shape check, not a deliverability check: the address is proven
  by sending to it (confirmation, magic link, invitation), so anything stricter
  here rejects valid addresses without proving anything.
  """

  import Ecto.Changeset

  @format ~r/\A[^\s]+@[^\s]+\z/
  @message "must have the @ sign and no spaces"
  @max_length 254

  @doc "Validates `field` holds a plausibly-shaped address of at most 254 bytes."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset, field) do
    changeset
    |> validate_format(field, @format, message: @message)
    |> validate_length(field, max: @max_length, count: :bytes)
  end
end

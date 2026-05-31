defmodule Emisar.Crypto do
  @moduledoc """
  Small crypto helpers shared by the auth-key, API-key, and token
  paths. Each verify path follows the same hash-then-compare shape;
  centralizing avoids three near-identical `secure_compare/2` defps.
  """

  @doc """
  Constant-time binary comparison. False when sizes differ — `:crypto.hash_equals/2`
  requires equal-length binaries. Use this anywhere a presented secret
  is compared against a stored hash.
  """
  def secure_compare(a, b)
      when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b),
      do: :crypto.hash_equals(a, b)

  def secure_compare(_, _), do: false
end

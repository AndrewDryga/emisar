defmodule Emisar.Marketing.Signup.Query do
  use Emisar, :query
  alias Emisar.Marketing.Signup

  def all, do: from(signups in Signup, as: :signups)

  # Email is citext, so this match is already case-insensitive.
  def by_email(queryable \\ all(), email),
    do: where(queryable, [signups: s], s.email == ^email)
end

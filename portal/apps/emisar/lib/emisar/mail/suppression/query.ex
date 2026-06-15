defmodule Emisar.Mail.Suppression.Query do
  use Emisar, :query
  alias Emisar.Mail.Suppression

  def all, do: from(suppressions in Suppression, as: :suppressions)

  # Email is citext, so this match is already case-insensitive.
  def by_email(queryable \\ all(), email),
    do: where(queryable, [suppressions: s], s.email == ^email)

  # Batch form for the Team-page deliverability overlay — citext, so still
  # case-insensitive against the given list.
  def by_emails(queryable \\ all(), emails),
    do: where(queryable, [suppressions: s], s.email in ^emails)
end

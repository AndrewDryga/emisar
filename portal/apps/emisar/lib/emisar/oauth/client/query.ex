defmodule Emisar.OAuth.Client.Query do
  use Emisar, :query
  alias Emisar.OAuth.Client

  def all, do: from(c in Client, as: :clients)

  def by_id(queryable \\ all(), id), do: where(queryable, [clients: c], c.id == ^id)

  # Never-authorized registrations (no operator ever consented) registered
  # before `cutoff` — the daily sweep's prune set. A once-authorized client is
  # never matched here (its `last_authorized_at` is set), so a live connection
  # is never pruned regardless of age.
  def never_authorized_before(queryable \\ all(), %DateTime{} = cutoff),
    do:
      where(
        queryable,
        [clients: c],
        is_nil(c.last_authorized_at) and c.inserted_at < ^cutoff
      )
end

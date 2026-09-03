defmodule Emisar.OAuth.Client.Query do
  use Emisar, :query
  alias Emisar.OAuth.Client

  def all, do: from(c in Client, as: :clients)

  def by_id(queryable \\ all(), id), do: where(queryable, [clients: c], c.id == ^id)

  @doc """
  Row lock for the consent mint's authoritative re-read (`FOR NO KEY UPDATE`).
  The registration the consent screen rendered is a request snapshot; issuance
  validates the callback against the locked row and stamps `last_authorized_at`
  on it, so both must see the same registration.
  """
  def lock_for_update(queryable),
    do: lock(queryable, "FOR NO KEY UPDATE")

  # Never-authorized registrations (no operator ever consented) registered
  # before `cutoff` — the daily sweep's prune set. A once-authorized client is
  # never matched here (its `last_authorized_at` is set), so a live connection
  # is never pruned regardless of age.
  def never_authorized_before(queryable \\ all(), %DateTime{} = cutoff) do
    where(
      queryable,
      [clients: c],
      is_nil(c.last_authorized_at) and c.inserted_at < ^cutoff
    )
  end

  @doc "Internal — the id page the abandoned-registration sweep deletes next. See `AuthorizationCode.Query.prunable_ids/2`."
  def prunable_ids(%DateTime{} = cutoff, limit) do
    all()
    |> never_authorized_before(cutoff)
    |> order_by([clients: c], asc: c.id)
    |> limit(^limit)
    |> select([clients: c], c.id)
  end

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [clients: c], c.id in ^ids)
end

defmodule Emisar.OAuth.Client.Query do
  use Emisar, :query
  alias Emisar.OAuth.Client

  def all, do: from(c in Client, as: :clients)

  def by_id(queryable \\ all(), id), do: where(queryable, [clients: c], c.id == ^id)

  def by_metadata_url(queryable \\ all(), url),
    do: where(queryable, [clients: c], c.client_id_metadata_url == ^url)

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
end

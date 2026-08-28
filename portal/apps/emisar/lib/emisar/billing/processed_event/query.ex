defmodule Emisar.Billing.ProcessedEvent.Query do
  use Emisar, :query
  alias Emisar.Billing.ProcessedEvent

  def all, do: from(events in ProcessedEvent, as: :events)

  def by_ids(queryable \\ all(), ids) when is_list(ids),
    do: where(queryable, [events: e], e.id in ^ids)

  @doc """
  A bounded page of dedup-row ids received before `cutoff` — what
  `Billing.Jobs.ProcessedEventRetention` deletes next.
  """
  def prunable_ids(%DateTime{} = cutoff, limit) when is_integer(limit) do
    all()
    |> where([events: e], e.received_at < ^cutoff)
    |> limit(^limit)
    |> select([events: e], e.id)
  end
end

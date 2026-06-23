defprotocol Emisar.Repo.Broadcastable do
  @moduledoc """
  A committed row that `Repo.commit_multi/2` fans out to live subscribers once
  its transaction commits.

  Implementing this protocol — rather than having `Repo` match a specific
  context's struct — keeps the dependency pointing the right way: `Repo` (infra)
  owns the interface and never references a context, while the context (e.g.
  `Emisar.Audit`) implements `broadcast/1` for its own schema.
  """
  @fallback_to_any false

  @doc "Broadcast this committed row to its live subscribers. Returns `:ok`."
  @spec broadcast(t()) :: :ok
  def broadcast(struct)
end

defimpl Emisar.Repo.Broadcastable, for: Emisar.Audit.Event do
  @moduledoc false
  # An audit event, once committed, fans out to the account-wide `:audit` topic
  # that AuditLive subscribes to. Living in the Audit context (not Repo) keeps
  # the dependency pointing the right way — the context depends on the infra
  # protocol, never the reverse.

  def broadcast(%Emisar.Audit.Event{} = event), do: Emisar.Audit.broadcast_event(event)
end

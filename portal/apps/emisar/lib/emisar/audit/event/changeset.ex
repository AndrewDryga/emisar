defmodule Emisar.Audit.Event.Changeset do
  use Emisar, :changeset
  alias Emisar.Audit.Event

  def create(attrs) do
    %Event{}
    |> cast(attrs, [
      :account_id,
      :occurred_at,
      :event_type,
      :actor_kind,
      :actor_id,
      :actor_label,
      :subject_kind,
      :subject_id,
      :subject_label,
      :ip_address,
      :user_agent,
      :request_id,
      :mcp_session_id,
      :payload
    ])
    |> validate_required([:account_id, :occurred_at, :event_type])
  end
end

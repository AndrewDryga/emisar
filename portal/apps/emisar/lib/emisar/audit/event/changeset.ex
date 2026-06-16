defmodule Emisar.Audit.Event.Changeset do
  use Emisar, :changeset
  alias Emisar.Audit.Event

  # Request-metadata is attacker-controllable on unauthenticated paths (a
  # failed sign-in carries the client's `user-agent` and forwarded IP).
  # The columns are varchar(255); TRUNCATE rather than let an over-long
  # value fail the insert — a rejected insert drops the audit row entirely,
  # letting an attacker suppress their own failed-attempt trail.
  @request_meta_fields [:ip_address, :user_agent, :request_id, :mcp_session_id]
  @request_meta_limit 255

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
      :auth_method,
      :mfa,
      :user_identity_id,
      :payload
    ])
    |> truncate_request_meta()
    |> validate_required([:account_id, :occurred_at, :event_type])
  end

  defp truncate_request_meta(changeset) do
    Enum.reduce(@request_meta_fields, changeset, fn field, acc ->
      update_change(acc, field, &truncate/1)
    end)
  end

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @request_meta_limit)
  defp truncate(value), do: value
end

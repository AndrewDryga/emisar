defmodule Emisar.Audit.Event.Changeset do
  use Emisar, :changeset
  alias Emisar.Audit.Event

  # Request-metadata is attacker-controllable on unauthenticated paths (a
  # failed sign-in carries the client's `user-agent` and forwarded IP).
  # The columns are varchar(255); TRUNCATE rather than let an over-long
  # value fail the insert — a rejected insert drops the audit row entirely,
  # letting an attacker suppress their own failed-attempt trail.
  @request_meta_fields [:ip_address, :user_agent, :request_id]
  @request_meta_limit 255
  # Audit events record runner and request failures, so payloads can originate
  # outside the control plane. Keep the event row even when its detail is too
  # large to retain safely: the marker preserves the fact and scale of the
  # event without making the audit log an unbounded JSONB sink.
  @max_payload_bytes 262_144

  def create(attrs) do
    %Event{}
    |> cast(attrs, [
      :account_id,
      :occurred_at,
      :retain_until,
      :event_type,
      :actor_kind,
      :actor_id,
      :actor_label,
      :target_kind,
      :target_id,
      :target_label,
      :ip_address,
      :user_agent,
      :request_id,
      :auth_method,
      :mfa,
      :user_identity_id,
      :payload
    ])
    |> truncate_request_meta()
    |> truncate_payload()
    |> validate_required([:account_id, :occurred_at, :event_type])
  end

  defp truncate_request_meta(changeset) do
    Enum.reduce(@request_meta_fields, changeset, fn field, acc ->
      update_change(acc, field, &truncate/1)
    end)
  end

  defp truncate(value) when is_binary(value), do: String.slice(value, 0, @request_meta_limit)
  defp truncate(value), do: value

  defp truncate_payload(changeset) do
    update_change(changeset, :payload, fn payload ->
      case Jason.encode(payload) do
        {:ok, json} when byte_size(json) > @max_payload_bytes ->
          %{"truncated" => true, "serialized_bytes" => byte_size(json)}

        _ ->
          payload
      end
    end)
  end
end

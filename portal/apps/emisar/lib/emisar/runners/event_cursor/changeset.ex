defmodule Emisar.Runners.EventCursor.Changeset do
  use Emisar, :changeset
  alias Emisar.Runners.EventCursor

  def upsert(runner_id, event_id) do
    %EventCursor{}
    |> cast(
      %{runner_id: runner_id, event_id: event_id, acked_at: now()},
      [:runner_id, :event_id, :acked_at]
    )
    |> validate_required([:runner_id, :event_id, :acked_at])
    |> unique_constraint([:runner_id, :event_id])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

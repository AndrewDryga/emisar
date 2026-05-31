defmodule Emisar.Runners.EventCursor do
  @moduledoc """
  Mirrors the runner-side outbox cursor. Records which runner-emitted
  `event_id`s the cloud has acknowledged so the cloud audit pipeline
  can dedupe on replays.
  """

  use Emisar, :schema

  schema "runner_event_cursors" do
    field :event_id, :string
    field :acked_at, :utc_datetime_usec

    belongs_to :runner, Emisar.Runners.Runner
  end
end

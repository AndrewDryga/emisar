defmodule Emisar.Runners.EventCursor do
  @moduledoc """
  Mirrors the runner-side outbox cursor. Records which runner-emitted
  `event_id`s the cloud has acknowledged, so the cloud audit pipeline
  can dedupe on replays.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runner_event_cursors" do
    field :event_id, :string
    field :acked_at, :utc_datetime_usec

    belongs_to :runner, Emisar.Runners.Runner
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:runner_id, :event_id, :acked_at])
    |> validate_required([:runner_id, :event_id, :acked_at])
    |> unique_constraint([:runner_id, :event_id])
  end
end

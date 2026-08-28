defmodule Emisar.Billing.ProcessedEvent do
  @moduledoc """
  One row per Paddle webhook we have already applied.

  The primary key IS Paddle's event id, so the dedup insert's conflict on it is
  what makes redelivery a no-op. No `timestamps()` — `received_at` is the only
  time this row has.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "paddle_processed_events" do
    field :event_type, :string
    field :received_at, :naive_datetime
  end
end

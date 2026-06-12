defmodule Emisar.Repo.Migrations.PaddleProcessedEvents do
  @moduledoc """
  Idempotency cache for Paddle webhook delivery. We insert the event id
  with a unique primary key inside the same transaction that mutates
  the subscription mirror; a retried webhook hits the unique
  constraint and is silently acked as already-processed.
  """
  use Ecto.Migration

  def change do
    create table(:paddle_processed_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :event_type, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create index(:paddle_processed_events, [:received_at])
  end
end

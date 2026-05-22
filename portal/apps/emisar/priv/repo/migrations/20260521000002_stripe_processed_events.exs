defmodule Emisar.Repo.Migrations.StripeProcessedEvents do
  use Ecto.Migration

  @moduledoc """
  Idempotency cache for Stripe webhook delivery. We insert the event id
  with a unique index inside the same transaction that mutates the
  subscription mirror; a retried webhook hits the unique constraint and
  is silently acked as already-processed.
  """

  def change do
    create table(:stripe_processed_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :event_type, :string, null: false
      add :received_at, :utc_datetime_usec, null: false
    end

    create index(:stripe_processed_events, [:received_at])
  end
end

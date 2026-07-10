defmodule Emisar.Fixtures.Runs do
  @moduledoc """
  Action-run test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runs.charge_progress_budget/2`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.{Fixtures, Repo}
  alias Emisar.Runs.ActionRun

  @doc """
  Persists a `:success` action run by default. Caller supplies `:account_id`
  (a runner is created in it) or nothing (a fresh account + runner). Override
  `:status`, `:action_id`, `:source`, `:request_id`, and `:inserted_at` (to land
  a run in a report window) as needed.
  """
  def create_run(attrs \\ %{}) do
    attrs = Map.new(attrs)

    runner =
      if attrs[:runner_id],
        do: nil,
        else: Fixtures.Runners.create_runner(Map.take(attrs, [:account_id]))

    params = %{
      account_id: attrs[:account_id] || runner.account_id,
      runner_id: attrs[:runner_id] || runner.id,
      request_id: attrs[:request_id] || Ecto.UUID.generate(),
      action_id: attrs[:action_id] || "svc.read",
      source: attrs[:source] || :operator,
      status: attrs[:status] || :success
    }

    {:ok, run} = params |> ActionRun.Changeset.create() |> Repo.insert()

    case attrs[:inserted_at] do
      %DateTime{} = ts -> run |> change(inserted_at: ts) |> Repo.update!()
      nil -> run
    end
  end

  @doc """
  Pre-spend a run's durable progress budget (`:events` / `:bytes`) so a
  boundary test can drive the ceiling without appending tens of thousands of
  real chunks. Writes the counters straight onto the row — a fixture builds
  rows without a Subject.
  """
  def charge_progress_budget(%ActionRun{} = run, opts \\ []) do
    run
    |> change(
      progress_event_count: Keyword.get(opts, :events, 0),
      progress_byte_count: Keyword.get(opts, :bytes, 0)
    )
    |> Repo.update!()
  end
end

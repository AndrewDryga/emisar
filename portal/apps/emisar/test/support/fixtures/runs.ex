defmodule Emisar.Fixtures.Runs do
  @moduledoc """
  Action-run test fixtures. Use via `alias Emisar.Fixtures`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.{Crypto, Fixtures, Repo, Runs}
  alias Emisar.Runners.Runner
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
      request_id: attrs[:request_id] || Crypto.run_request_id(),
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

  @doc """
  Places a run in an in-flight status for query and timeout setup. It does not
  claim runner-connection ownership; tests of runner messages use the real
  connection-owned APIs.
  """
  def put_status(%ActionRun{} = run, :sent) do
    run
    |> ActionRun.Changeset.transition(:sent, %{sent_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  def put_status(%ActionRun{} = run, :running) do
    now = DateTime.utc_now()

    run
    |> ActionRun.Changeset.transition(:running, %{sent_at: run.sent_at || now, started_at: now})
    |> Repo.update!()
  end

  @doc "Finalizes a run through the same connection-owned path as a runner result."
  def finish(%ActionRun{} = run, payload) when is_map(payload) do
    runner = Repo.get!(Runner, run.runner_id)
    payload = Map.put(payload, "request_id", run.request_id)

    Runs.finalize_from_connection(
      run.account_id,
      runner.id,
      runner.connection_generation,
      runner.connection_lease_id,
      payload
    )
  end
end

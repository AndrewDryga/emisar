defmodule Emisar.Fixtures.Runs do
  @moduledoc """
  Action-run test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.Runs.charge_progress_budget/2`.
  """

  import Ecto.Changeset, only: [change: 2]
  alias Emisar.Repo
  alias Emisar.Runs.ActionRun

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

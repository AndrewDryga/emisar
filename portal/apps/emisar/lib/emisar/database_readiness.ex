defmodule Emisar.DatabaseReadiness do
  @moduledoc false

  use GenServer
  require Logger

  @check_interval :timer.seconds(1)
  @required_successes 3

  def ready? do
    check =
      Application.get_env(:emisar, :database_health_check, fn ->
        Ecto.Adapters.SQL.query(Emisar.Repo, "SELECT 1", [], timeout: 2_000)
      end)

    match?({:ok, _result}, check.())
  end

  def start_link(_opts) do
    wait_for_database(0)
    GenServer.start_link(__MODULE__, :ready, name: __MODULE__)
  end

  @impl true
  def init(:ready), do: {:ok, nil}

  defp wait_for_database(@required_successes), do: :ok

  defp wait_for_database(successes) do
    next_successes =
      if ready?() do
        successes + 1
      else
        Logger.warning("database not ready; retrying")
        0
      end

    if next_successes < @required_successes, do: Process.sleep(@check_interval)
    wait_for_database(next_successes)
  end
end

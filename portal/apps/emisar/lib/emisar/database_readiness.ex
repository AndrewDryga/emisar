defmodule Emisar.DatabaseReadiness do
  @moduledoc false

  use GenServer
  require Logger

  @check_interval :timer.seconds(1)

  def ready? do
    check =
      Emisar.Config.get_env(:emisar, :database_health_check, fn ->
        Ecto.Adapters.SQL.query(Emisar.Repo, "SELECT 1", [], timeout: 2_000)
      end)

    match?({:ok, _result}, check.())
  end

  def start_link(_opts) do
    wait_for_database()
    GenServer.start_link(__MODULE__, :ready, name: __MODULE__)
  end

  @impl true
  def init(:ready), do: {:ok, nil}

  defp wait_for_database do
    if ready?() do
      :ok
    else
      Logger.warning("database not ready; retrying")
      Process.sleep(@check_interval)
      wait_for_database()
    end
  end
end

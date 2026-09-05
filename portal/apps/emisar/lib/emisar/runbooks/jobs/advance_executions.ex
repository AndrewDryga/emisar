defmodule Emisar.Runbooks.Jobs.AdvanceExecutions do
  @moduledoc """
  Restarts missed runbook continuations and dispatches due wait observations.
  """
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.seconds(5),
    initial_delay: :timer.seconds(5)

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(_config) do
    _advanced = Emisar.Runbooks.recover_due()
    :ok
  end
end

defmodule Emisar.Audit.Rejection do
  @moduledoc """
  Internal receipt for a rejected domain operation whose transaction must roll back.

  Capture one allowlisted audit changeset at the failing gate. Carry it through
  the failed Multi, then record it synchronously at the outer domain boundary.
  Successful mutations keep their audit rows inside their own transaction.
  """

  alias Emisar.{Audit, Repo}
  require Logger

  @derive {Inspect, only: [:reason]}
  @enforce_keys [:reason, :event]
  defstruct [:reason, :event]

  def new(reason, %Ecto.Changeset{data: %Audit.Event{}} = event),
    do: %__MODULE__{reason: reason, event: event}

  def reason(%__MODULE__{reason: reason}), do: reason
  def reason(reason), do: reason

  def with_reason(%__MODULE__{} = rejection, reason), do: %{rejection | reason: reason}
  def with_reason(_original, reason), do: reason

  @doc "Record a rejection only after the owning transaction has rolled back."
  def finish({:error, %__MODULE__{} = rejection} = result) do
    if Repo.in_transaction?() do
      result
    else
      record(rejection.event)
      {:error, rejection.reason}
    end
  end

  def finish(result), do: result

  defp record(event) do
    case Audit.record(event) do
      {:ok, _event} -> :ok
      {:error, _changeset} -> log_record_failure()
    end
  rescue
    # The operation is already rejected. A failed receipt write must not turn
    # its established error into a database exception or expose the payload.
    _error in [Ecto.ConstraintError, Postgrex.Error, DBConnection.ConnectionError] ->
      log_record_failure()
  end

  defp log_record_failure, do: Logger.error("Could not record rejected action audit event")
end

defmodule EmisarWeb.TransportReason do
  @moduledoc """
  Converts runner transport termination reasons into stable operator copy.

  The raw reason remains diagnostic data in the runner and audit records. The
  UI gets only a useful sentence, or no message when the close is routine.
  """

  @spec disconnect_message(term()) :: String.t() | nil
  def disconnect_message(reason) when is_binary(reason) do
    case String.trim(reason) do
      reason when reason in ["", "normal", "closed", "{:error, :closed}", "reconnect"] -> nil
      "shutdown" -> "Runner service stopped."
      "shutdown:" <> _reason -> "Runner service stopped."
      _reason -> "Connection ended unexpectedly."
    end
  end

  def disconnect_message(_reason), do: nil
end

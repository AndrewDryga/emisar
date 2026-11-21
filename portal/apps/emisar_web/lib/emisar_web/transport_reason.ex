defmodule EmisarWeb.TransportReason do
  @moduledoc """
  Converts runner transport termination reasons into stable operator copy.

  The raw reason remains diagnostic data in the runner and audit records. The
  UI gets only a useful sentence, or no message when the close is routine.
  """

  # `:remote` is the runner closing the socket itself (a restart, a stop, or a
  # reconnect); the transport cannot tell which, so it reads as routine.
  @routine_reasons ["", "normal", "closed", "{:error, :closed}", "reconnect", ":remote"]

  @spec disconnect_message(term()) :: String.t() | nil
  def disconnect_message(reason) when is_binary(reason) do
    if String.trim(reason) in @routine_reasons, do: nil, else: "Connection ended unexpectedly."
  end

  def disconnect_message(_reason), do: nil
end

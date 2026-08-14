defmodule EmisarWeb.FleetStates do
  @moduledoc "The single source of the operator-facing word for each runner connection state — consumed by the fleet posture lines, the runner status badge, and the staff console's fleet counts."

  # `Emisar.Runners.connection_state/1` atom => label, in fleet-posture order:
  # the healthy state first, then the ones an operator has to look at. ONE word
  # for the offline fact console-wide (the MCP wire keeps its own stable
  # "disconnected"); `label/1` raises on any state not listed here, so a new
  # connection state can't render blank.
  @states [
    online: "connected",
    offline: "offline",
    pending: "pending",
    disabled: "disabled"
  ]

  @doc "The operator-facing label for a `Runners.connection_state/1` atom; raises `KeyError` on an unknown state so drift is loud."
  def label(state), do: Keyword.fetch!(@states, state)
end

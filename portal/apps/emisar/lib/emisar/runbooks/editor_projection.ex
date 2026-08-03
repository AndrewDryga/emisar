defmodule Emisar.Runbooks.EditorProjection do
  @moduledoc """
  The runbook editor's typed view of current authoring facts: the target
  runners a step may select, and the trusted catalog they can execute.

  It is advisory authoring state that narrows what an operator can author.
  Save, publish, and dispatch still compile against current facts, so a
  projection that has since drifted can only make the editor conservative.
  """

  alias Emisar.Catalog

  defstruct targets: [], catalog: %Catalog.EditorProjection{}

  @type target :: %{
          id: String.t(),
          runner_ref: String.t(),
          name: String.t(),
          group: String.t() | nil
        }

  @type action :: %{
          pack_id: String.t(),
          action_id: String.t(),
          title: String.t() | nil,
          risk: String.t() | nil,
          args: [map()]
        }

  @type t :: %__MODULE__{targets: [target()], catalog: Catalog.EditorProjection.t()}
end

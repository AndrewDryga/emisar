defmodule EmisarWeb.PacksRegistry.Action do
  @moduledoc """
  One action's catalog metadata as parsed from `pack/actions/<id>.yaml`.
  Lives in its own file so it compiles before `EmisarWeb.PacksRegistry`,
  which embeds these structs into a compile-time module attribute.
  """

  @enforce_keys [:id, :title, :kind, :risk]
  defstruct [:id, :title, :kind, :risk]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          kind: String.t(),
          risk: String.t()
        }
end

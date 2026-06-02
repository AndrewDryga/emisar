defmodule EmisarWeb.PacksRegistry.Pack do
  @moduledoc """
  One pack's catalog metadata as parsed from `pack/pack.yaml` plus the
  actions discovered under `pack/actions/`. Lives in its own file so it
  compiles before `EmisarWeb.PacksRegistry`, which embeds these structs
  into a compile-time module attribute.
  """

  @enforce_keys [:id, :name, :version, :description, :vendor, :actions]
  defstruct [
    :id,
    :name,
    :version,
    :description,
    :vendor,
    :homepage,
    :requires_os,
    :requires_binaries,
    actions: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t(),
          vendor: String.t(),
          homepage: String.t() | nil,
          requires_os: [String.t()],
          requires_binaries: [String.t()],
          actions: [EmisarWeb.PacksRegistry.Action.t()]
        }
end

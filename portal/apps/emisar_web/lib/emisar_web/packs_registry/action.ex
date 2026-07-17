defmodule EmisarWeb.PacksRegistry.Action do
  @moduledoc """
  One action's catalog metadata as parsed from `pack/actions/<id>.yaml`.
  Lives in its own file so it compiles before `EmisarWeb.PacksRegistry`,
  which embeds these structs into a compile-time module attribute.
  """

  @enforce_keys [:id, :title, :kind, :risk]
  # `command` is the exec-kind action's `execution.command` template
  # (`%{binary, argv}`) — the argv slots still carry their `{{ args.x }}`
  # placeholders. It drives the approval-page command preview (resolved
  # against the run's args). `nil` for script-kind actions, whose real
  # invocation is an on-host script path we can't render from here.
  # `description` is the pack author's operator doc — rendered (collapsed) on
  # the public pack page; lenient default so a docless third-party catalog
  # entry still parses.
  defstruct [:id, :title, :kind, :risk, :command, description: ""]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          kind: String.t(),
          risk: String.t(),
          command: %{binary: String.t(), argv: [String.t()]} | nil,
          description: String.t()
        }
end

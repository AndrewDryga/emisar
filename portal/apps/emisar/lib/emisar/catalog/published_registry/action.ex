defmodule Emisar.Catalog.PublishedRegistry.Action do
  @moduledoc """
  One action's catalog metadata as parsed from `pack/actions/<id>.yaml`.
  Lives in its own file so a reader can see the shape
  `Emisar.Catalog.PublishedRegistry` hands to the public pack pages and the
  approval-page command preview.
  """

  @enforce_keys [:id, :title, :kind, :risk]
  # `command` is the exec-kind action's `execution.command` template
  # (`%{binary, argv}`) — the argv slots still carry their `{{ args.x }}`
  # placeholders. It drives the approval-page command preview (resolved
  # against the run's args). `nil` for script-kind actions, whose real
  # invocation is an on-host script path we can't render from here.
  # `args` is the action's declared argument list exactly as published — the
  # `default` and `sensitive` facts the preview renders and masks by. It rides
  # beside `command` because both must come from the SAME hash-proven pack: a
  # runner's mutable advertisement must never supply either.
  # `description` is the pack author's operator doc — rendered (collapsed) on
  # the public pack page.
  defstruct [:id, :title, :kind, :risk, :command, args: [], description: ""]

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          kind: String.t(),
          risk: String.t(),
          command: %{binary: String.t(), argv: [String.t()]} | nil,
          args: [map()],
          description: String.t()
        }
end

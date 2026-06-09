defmodule Emisar.Repo.Filter.Range do
  @moduledoc """
  Inclusive range used by `:range` filter types. `from` or `to` may be
  nil for open-ended ranges. When both are equal the filter behaves as
  an equality check.
  """

  @type t :: %__MODULE__{from: term() | nil, to: term() | nil}
  defstruct from: nil, to: nil
end

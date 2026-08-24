defmodule Emisar.SSO.SCIMUserUpdate do
  @moduledoc """
  The typed desired state a SCIM PATCH or PUT asks of one directory user,
  parsed by the wire boundary and applied by `Emisar.SSO.scim_update_user/3`
  as one atomic transition.

  `name` — `:keep` (the operation carries no rename), `{:replace, full_name}`
  (a whole name was stated), or `{:merge, components}` where `components` is a
  map with `:given` / `:family` halves and the half the operation left alone
  keeps its current value (merged inside the transaction, against the row the
  transition locks). `active` — `:keep` or the desired boolean lifecycle state.
  """

  @type name ::
          :keep
          | {:replace, String.t()}
          | {:merge, %{optional(:given) => String.t(), optional(:family) => String.t()}}

  @type t :: %__MODULE__{name: name(), active: :keep | boolean()}

  defstruct name: :keep, active: :keep
end

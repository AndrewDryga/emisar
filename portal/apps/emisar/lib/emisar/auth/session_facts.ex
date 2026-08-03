defmodule Emisar.Auth.SessionFacts do
  @moduledoc """
  What the caller may know about one of their own sessions: the row id
  revocation needs, whether it is the session making this request, and the
  device metadata the Profile page renders.

  Deliberately narrow — the session token, its stored digest, the raw metadata
  map, and the session's auth provenance stay inside `Emisar.Auth`, so a
  rendering surface has no credential material to leak.
  """

  @enforce_keys [:id, :current?, :ip_address, :user_agent, :inserted_at]
  defstruct [:id, :current?, :ip_address, :user_agent, :inserted_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          current?: boolean(),
          ip_address: String.t() | nil,
          user_agent: String.t() | nil,
          inserted_at: DateTime.t()
        }
end

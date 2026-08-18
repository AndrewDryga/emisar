defmodule Emisar.SSO.SCIMUser do
  @moduledoc """
  The public directory-user projection the SCIM wire boundary renders: the
  server-issued `id`, the directory-owned `external_id`, the human-readable
  `user_name` handle, the synced `display_name`, and the
  authoritative effective `active` state. Built by `Emisar.SSO`'s `scim_*`
  reads from the identity, user, and membership it scopes and loads;
  `EmisarWeb.SCIM.Resource` only maps these fields to RFC 7643 names.

  `active` is what the IdP is told, and it has to be the truth: the identity's
  SCIM lifecycle flag AND a live, non-suspended membership. A manual
  break-glass hold or a removed membership reports inactive even while the
  directory still asserts the identity active.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          external_id: String.t(),
          user_name: String.t(),
          display_name: String.t() | nil,
          active: boolean()
        }

  defstruct [:id, :external_id, :user_name, :display_name, :active]
end

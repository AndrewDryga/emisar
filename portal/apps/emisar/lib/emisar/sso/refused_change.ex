defmodule Emisar.SSO.RefusedChange do
  @moduledoc """
  One change a directory pushed over SCIM that emisar refused, as the
  connection page lists it: what the directory tried (`change`), why emisar
  said no (`reason`), the label the directory knows the person or group by
  (`resource`), and when. `id` is the audit event that recorded it.

  SCIM sends each change once and the identity provider retries a refused one
  on its own schedule, so the refusal stays invisible until someone reads the
  provider's logs. `Emisar.SSO.SCIM` records each one in the audit trail and
  `Emisar.SSO.list_refused_changes/2` reads them back into this shape. The two
  lists below are the whole vocabulary: a recorded value outside them is never
  turned into an atom.
  """

  @changes ~w[add_user update_user suspend_user add_group update_group remove_group]a

  # `invalid_value` stands for a changeset the directory's values failed; every
  # other reason is the SCIM error itself.
  @reasons ~w[
    last_owner invitation_pending identifier_taken identity_pending_approval
    member_email_taken too_many_scim_operations invalid_scim_active
    unsupported_scim_patch invalid_scim_group invalid_value
  ]a

  @type change ::
          :add_user | :update_user | :suspend_user | :add_group | :update_group | :remove_group

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          change: change(),
          reason: atom(),
          resource: String.t(),
          refused_at: DateTime.t()
        }

  defstruct [:id, :change, :reason, :resource, :refused_at]

  @doc "Every change a refusal can name."
  def changes, do: @changes

  @doc "Every reason a refusal can carry."
  def reasons, do: @reasons
end

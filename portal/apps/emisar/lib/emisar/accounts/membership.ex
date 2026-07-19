defmodule Emisar.Accounts.Membership do
  @moduledoc """
  Joins users to accounts with a role. A user can be in many accounts;
  an account has many users.
  """
  use Emisar, :schema
  alias Emisar.Auth

  @roles Auth.Role.all()
  @runner_access_modes Emisar.Accounts.RunnerAccess.modes()

  schema "account_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :operator
    field :runner_access_mode, Ecto.Enum, values: @runner_access_modes, default: :none
    field :runner_access_directory_managed, :boolean, default: false
    field :directory_provider_id, Ecto.UUID
    field :directory_authorization_version, :integer, default: 0
    field :directory_authorization_pending_version, :integer
    # True when a directory sync (SCIM group->role recompute) owns this role, so
    # the operator role-change path (`Accounts.update_membership_role`) rejects a
    # manual change independently of the UI. Set by the sync write path, cleared
    # when SCIM is disabled for the provider.
    field :directory_managed, :boolean, default: false
    # True when a directory sync (SCIM `active:false`/DELETE) owns this suspension,
    # so `Accounts.reinstate_membership` refuses a manual reinstate (only the IdP
    # reactivating lifts it). Set by the SCIM deprovision write path.
    field :directory_suspended, :boolean, default: false
    field :invitation_token_digest, :string
    field :invitation_accepted_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :invited_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end

  @doc "True when a member's access to this tenant has been suspended (`disabled_at` set)."
  def disabled?(%__MODULE__{disabled_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false
end

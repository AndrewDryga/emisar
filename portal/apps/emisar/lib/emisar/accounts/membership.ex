defmodule Emisar.Accounts.Membership do
  @moduledoc """
  Joins users to accounts with a role. A user can be in many accounts;
  an account has many users.
  """
  use Emisar, :schema
  alias Emisar.Auth

  @roles Auth.Role.all()
  @runner_access_modes Emisar.Accounts.RunnerAccess.modes()
  @pack_access_modes Emisar.Accounts.RunnerAccess.pack_modes()

  schema "account_memberships" do
    field :role, Ecto.Enum, values: @roles, default: :operator
    field :runner_access_mode, Ecto.Enum, values: @runner_access_modes, default: :none
    # The pack dimension of the same grant — which packs the member may run on
    # the runners above. A flat, bounded id list, so it rides two columns rather
    # than the normalized rows the runner dimension needs for its write trigger.
    field :pack_access_mode, Ecto.Enum, values: @pack_access_modes, default: :all
    field :pack_scope_pack_ids, {:array, :string}, default: []
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
    # The directory's name for this member, owned by THIS account. `users.full_name`
    # is the person's own attribute and deliberately cross-account, so a rename
    # from one workspace's IdP must not rewrite how they read in another's.
    field :directory_display_name, :string
    field :invitation_token_digest, :string, redact: true
    field :invitation_sent_to, :string
    field :invitation_email_changed_at, :utc_datetime_usec
    field :invitation_accepted_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :user, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :invited_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :disabled_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end

  @doc "True when a member's access to this tenant has been suspended (`disabled_at` set)."
  def disabled?(%__MODULE__{disabled_at: %DateTime{}}), do: true
  def disabled?(%__MODULE__{}), do: false
end

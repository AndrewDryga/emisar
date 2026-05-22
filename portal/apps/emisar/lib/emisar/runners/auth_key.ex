defmodule Emisar.Runners.AuthKey do
  @moduledoc """
  A bootstrap secret an operator generates in the UI, drops into a VM
  via cloud-init/Terraform, and the runner presents on first connect.
  Reusable (stable VM fleets) or single-use (ephemeral / autoscaler).

  Stored as `key_prefix` (e.g. "emkey-auth-AB12") + `key_hash`. Raw
  key is only returned to the operator at creation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runner_auth_keys" do
    field :key_prefix, :string
    field :key_hash, :binary, redact: true
    field :description, :string
    field :group, :string
    field :reusable, :boolean, default: false
    field :max_uses, :integer
    field :uses_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :created_by, Emisar.Accounts.User
    belongs_to :revoked_by, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:account_id, :created_by_id, :description, :group, :reusable, :max_uses, :expires_at])
    |> validate_required([:account_id])
    |> validate_length(:description, max: 200)
  end

  def usage_changeset(key, at \\ DateTime.utc_now()) do
    change(key,
      last_used_at: DateTime.truncate(at, :microsecond),
      uses_count: key.uses_count + 1
    )
  end

  def revoke_changeset(key, by_user_id, at \\ DateTime.utc_now()) do
    change(key,
      revoked_at: DateTime.truncate(at, :microsecond),
      revoked_by_id: by_user_id
    )
  end

  @doc "Is this key currently presentable?"
  def usable?(%__MODULE__{} = key) do
    cond do
      not is_nil(key.revoked_at) -> false
      key.expires_at && DateTime.compare(DateTime.utc_now(), key.expires_at) == :gt -> false
      not key.reusable and key.uses_count > 0 -> false
      key.max_uses && key.uses_count >= key.max_uses -> false
      true -> true
    end
  end
end

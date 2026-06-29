defmodule Emisar.Runners.AuthKey do
  @moduledoc """
  Bootstrap secret an operator generates in the UI, drops onto a VM,
  and the runner presents on first connect. Reusable for stable VM
  fleets; single-use for ephemeral / autoscaler use-cases.

  Stored as `key_prefix` (e.g. "emkey-auth-AB12") + `key_hash`. The
  raw key is only returned to the operator at creation.
  """
  use Emisar, :schema

  schema "runner_auth_keys" do
    field :key_prefix, :string
    field :key_hash, :binary, redact: true
    field :description, :string
    field :reusable, :boolean, default: false
    field :max_uses, :integer
    field :uses_count, :integer, default: 0
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # Set when the dashboard auto-mints this key for the install
    # command. Cleared the moment a runner successfully registers with
    # it (at which point the key becomes permanent and visible in
    # lists). While this is non-nil AND last_used_at is nil, the key
    # is "tentative": invisible in UI, subject to ring eviction beyond
    # the per-account cap.
    field :auto_generated_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :created_by, Emisar.Users.User, where: [deleted_at: nil]
    belongs_to :revoked_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end

  @doc """
  True when the key is auto-generated AND has never been used. Drives
  UI visibility (hidden) and ring eviction (only auto-unused keys get
  evicted; once bound, the key stays).
  """
  def auto_unused?(%__MODULE__{auto_generated_at: nil}), do: false
  def auto_unused?(%__MODULE__{last_used_at: ts}) when not is_nil(ts), do: false
  def auto_unused?(%__MODULE__{}), do: true

  @doc "Is this key currently presentable for a runner registration?"
  def usable?(%__MODULE__{} = key) do
    cond do
      not is_nil(key.revoked_at) -> false
      not is_nil(key.deleted_at) -> false
      key.expires_at && DateTime.compare(DateTime.utc_now(), key.expires_at) == :gt -> false
      not key.reusable and key.uses_count > 0 -> false
      key.max_uses && key.uses_count >= key.max_uses -> false
      true -> true
    end
  end
end

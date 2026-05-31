defmodule Emisar.Runners.AuthKey.Changeset do
  @moduledoc """
  Changesets for runner auth keys: create / mint-install (auto-generated)
  / revoke / soft-delete / usage. The raw key only ever flows through
  `create/2` and `mint_install/2` return values — `key_hash` is the
  persisted form.
  """
  use Emisar, :changeset
  alias Emisar.Runners.AuthKey

  def create(account_id, user_id, prefix, hash, attrs) do
    %AuthKey{}
    |> cast(attrs, [:description, :group, :reusable, :max_uses, :expires_at])
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id])
    |> validate_length(:description, max: 200)
  end

  def mint_install(account_id, user_id, prefix, hash, attrs \\ %{}) do
    %AuthKey{}
    |> cast(attrs, [:description, :group])
    |> put_default_value(:description, "Dashboard install command")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:reusable, false)
    |> put_change(:auto_generated_at, now())
    |> validate_required([:account_id])
  end

  def usage(%AuthKey{} = key) do
    change(key,
      last_used_at: now(),
      uses_count: key.uses_count + 1
    )
  end

  def revoke(%AuthKey{} = key, by_user_id) do
    change(key, revoked_at: now(), revoked_by_id: by_user_id)
  end

  def delete(%AuthKey{} = key) do
    change(key, deleted_at: now())
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

defmodule Emisar.ApiKeys.ApiKey.Changeset do
  use Emisar, :changeset
  alias Emisar.ApiKeys.ApiKey

  @valid_scopes ~w(actions:read actions:execute runbooks:execute audit:read)

  def create(account_id, user_id, prefix, hash, attrs) do
    %ApiKey{}
    |> cast(attrs, [
      :name,
      :description,
      :runner_filter,
      :runner_group_filter,
      :scopes,
      :expires_at
    ])
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id, :name, :scopes])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_subset(:scopes, @valid_scopes)
  end

  def mint_quick(account_id, user_id, prefix, hash, attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name])
    |> put_default_value(:name, "Quick connect (auto)")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:scopes, ["actions:read", "actions:execute"])
    |> put_change(:auto_generated_at, now())
    |> validate_required([:account_id, :name])
  end

  def usage(%ApiKey{} = key) do
    # First MCP call promotes an auto-minted key to permanent (visible,
    # audit-logged). Clearing auto_generated_at is the visibility flip.
    change(key, last_used_at: now(), auto_generated_at: nil)
  end

  def revoke(%ApiKey{} = key, by_user_id) do
    change(key, revoked_at: now(), revoked_by_id: by_user_id)
  end

  def delete(%ApiKey{} = key), do: change(key, deleted_at: now())

  def valid_scopes, do: @valid_scopes

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

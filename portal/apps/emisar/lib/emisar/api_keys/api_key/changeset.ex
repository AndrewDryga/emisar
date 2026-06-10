defmodule Emisar.ApiKeys.ApiKey.Changeset do
  use Emisar, :changeset
  alias Emisar.ApiKeys.ApiKey

  # `runbooks:execute` used to live here but the MCP API never grew
  # a runbook-dispatch endpoint, so a key minted with only that scope
  # silently couldn't do anything. Drop until we ship the endpoint.
  @valid_scopes ~w(actions:read actions:execute audit:read)

  @doc """
  Validation-only changeset for the operator create form. Casts the
  operator-facing fields and runs the same `name` validations as
  `create/6`, but mints no secret and touches no DB — so the LiveView
  can drive `phx-change` validation and render inline field errors
  without generating a key on every keystroke. `expires_at` is left
  out of the cast: the datetime-local input emits `YYYY-MM-DDTHH:MM`
  (no seconds/zone), which Ecto can't cast to `:utc_datetime_usec`; it
  round-trips for redisplay via the changeset params and is parsed when
  the key is actually created.
  """
  def form(attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
  end

  def create(account_id, user_id, membership_id, prefix, hash, attrs) do
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
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id, :name, :scopes])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_subset(:scopes, @valid_scopes)
  end

  def mint_quick(account_id, user_id, membership_id, prefix, hash, attrs \\ %{}) do
    %ApiKey{}
    |> cast(attrs, [:name, :runner_filter, :runner_group_filter])
    |> put_default_value(:name, "Quick connect (auto)")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:created_by_membership_id, membership_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:scopes, ["actions:read", "actions:execute"])
    |> put_change(:auto_generated_at, DateTime.utc_now())
    |> validate_required([:account_id, :name])
  end

  def usage(%ApiKey{} = key) do
    # First MCP call promotes an auto-minted key to permanent (visible,
    # audit-logged). Clearing auto_generated_at is the visibility flip.
    change(key, last_used_at: DateTime.utc_now(), auto_generated_at: nil)
  end

  # The MCP `initialize` clientInfo for this key — already sanitized by the
  # caller to a small string map. Snapshotted onto runs dispatched after.
  def record_client_info(%ApiKey{} = key, info) when is_map(info),
    do: change(key, last_client_info: info)

  def revoke(%ApiKey{} = key, by_user_id) do
    change(key, revoked_at: DateTime.utc_now(), revoked_by_id: by_user_id)
  end

  def delete(%ApiKey{} = key), do: change(key, deleted_at: DateTime.utc_now())

  def valid_scopes, do: @valid_scopes
end

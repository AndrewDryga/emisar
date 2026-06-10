defmodule Emisar.Runners.AuthKey.Changeset do
  @moduledoc """
  Changesets for runner auth keys: create / mint-install (auto-generated)
  / revoke / soft-delete / usage. The raw key only ever flows through
  `create/2` and `mint_install/2` return values — `key_hash` is the
  persisted form.
  """
  use Emisar, :changeset
  alias Emisar.Runners.AuthKey

  @doc """
  Validation-only changeset for the operator create form. Casts the
  operator-facing fields and runs the same field validations as `create/5`,
  but mints no secret — so the LiveView can drive `phx-change` validation and
  render inline field errors without generating a key on every keystroke.
  `expires_at` is left out of the cast: the datetime-local input emits
  `YYYY-MM-DDTHH:MM` (no seconds/zone), which Ecto can't cast to
  `:utc_datetime_usec`; it round-trips for redisplay via the changeset params
  and is parsed when the key is actually created.
  """
  def form(attrs \\ %{}) do
    %AuthKey{}
    |> cast(attrs, [:description, :group, :reusable, :max_uses])
    |> validate_length(:description, max: 200)
    |> validate_number(:max_uses, greater_than: 0)
  end

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

  # Mirrors Emisar.Runners' mint size ("emkey-auth-" + 16 random chars);
  # the round-trip test on `peek_auth_key_by_secret/1` breaks on drift.
  @auth_key_prefix_size 27

  @doc """
  Seed/dev-bootstrap variant of `create/5` deriving prefix + hash from a
  caller-supplied raw secret (docker-compose's fixed dev key, test
  fixtures). Production keys MUST mint through
  `Emisar.Runners.create_auth_key/2` — a known raw value defeats the
  server-side randomization that makes auth keys credentials.
  """
  def create_with_secret(account_id, user_id, raw, attrs)
      when is_binary(raw) and byte_size(raw) >= @auth_key_prefix_size do
    prefix = String.slice(raw, 0, @auth_key_prefix_size)
    create(account_id, user_id, prefix, Emisar.Crypto.hash(raw), attrs)
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
    |> put_change(:auto_generated_at, DateTime.utc_now())
    |> validate_required([:account_id])
  end

  def usage(%AuthKey{} = key) do
    change(key,
      last_used_at: DateTime.utc_now(),
      uses_count: key.uses_count + 1
    )
  end

  def revoke(%AuthKey{} = key, by_user_id) do
    change(key, revoked_at: DateTime.utc_now(), revoked_by_id: by_user_id)
  end

  def delete(%AuthKey{} = key) do
    change(key, deleted_at: DateTime.utc_now())
  end
end

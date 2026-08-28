defmodule Emisar.Runners.EnrollmentKey.Changeset do
  @moduledoc """
  Changesets for runner enrollment keys: create / mint-install (auto-generated)
  / revoke / soft-delete / usage. The raw key only ever flows through
  `create/5` and `mint_install/5` return values — `key_hash` is the
  persisted form.
  """
  use Emisar, :changeset
  alias Emisar.BrowserInput
  alias Emisar.Runners.EnrollmentKey

  @fields ~w[description reusable max_uses expires_at]a

  @doc """
  Validation-only changeset for the operator create form — the same casting,
  normalization and operator-field validations `create/5` applies, but it mints
  no secret and touches no DB, so the LiveView can drive `phx-change`
  validation and render inline field errors without generating a key on every
  keystroke. Submitting the same params still goes through `create/5`.
  """
  def form(attrs \\ %{}), do: cast_operator_input(%EnrollmentKey{}, attrs)

  def create(account_id, user_id, prefix, hash, attrs) do
    %EnrollmentKey{}
    |> cast_operator_input(attrs)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> validate_required([:account_id])
  end

  # The one interpretation of operator-typed key attributes, so the create form
  # can never accept — or reject — what the mint would decide differently.
  defp cast_operator_input(%EnrollmentKey{} = key, attrs) do
    attrs = BrowserInput.normalize(attrs, blank: [:description], expiry: [:expires_at])

    key
    |> cast(attrs, @fields)
    |> validate_length(:description, max: 200)
    # A max_uses of 0 mints a key that's dead on arrival (uses_count 0 >= 0).
    |> validate_number(:max_uses, greater_than: 0)
    |> drop_max_uses_unless_reusable()
  end

  # A single-use key is spent on its first registration, so a cap on top of it
  # never applies — canonicalize it to nil rather than persist a number the
  # list would then render. Dropping the change can't erase a cast error, so a
  # malformed max_uses still comes back to the operator on its own field.
  defp drop_max_uses_unless_reusable(changeset) do
    if get_field(changeset, :reusable),
      do: changeset,
      else: delete_change(changeset, :max_uses)
  end

  # Mirrors Emisar.Runners' mint size ("emkey-enroll-" + 16 random chars => 29);
  # the round-trip test on `peek_enrollment_key_by_secret/1` breaks on drift.
  @enrollment_key_prefix_size 29

  @doc """
  Seed/dev-bootstrap variant of `create/5` deriving prefix + hash from a
  caller-supplied raw secret (docker-compose's fixed dev key, test
  fixtures). Production keys MUST mint through
  `Emisar.Runners.create_enrollment_key/2` — a known raw value defeats the
  server-side randomization that makes enrollment keys credentials.
  """
  def create_with_secret(account_id, user_id, raw, attrs)
      when is_binary(raw) and byte_size(raw) >= @enrollment_key_prefix_size do
    prefix = String.slice(raw, 0, @enrollment_key_prefix_size)
    create(account_id, user_id, prefix, Emisar.Crypto.hash(raw), attrs)
  end

  def mint_install(account_id, user_id, prefix, hash, attrs \\ %{}) do
    %EnrollmentKey{}
    |> cast(attrs, [:description])
    |> put_default_value(:description, "Console install command")
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> put_change(:key_prefix, prefix)
    |> put_change(:key_hash, hash)
    |> put_change(:reusable, false)
    |> put_change(:auto_generated_at, DateTime.utc_now())
    |> validate_required([:account_id])
  end

  def usage(%EnrollmentKey{} = key) do
    change(key,
      last_used_at: DateTime.utc_now(),
      uses_count: key.uses_count + 1
    )
  end

  # Idempotent: re-revoking an already-revoked key is a no-op (no re-stamp), so
  # the lock-race path (caller passed a stale-active key) can't move revoked_at.
  def revoke(%EnrollmentKey{revoked_at: revoked_at} = key, _by_user_id)
      when not is_nil(revoked_at),
      do: change(key)

  def revoke(%EnrollmentKey{} = key, by_user_id) do
    change(key, revoked_at: DateTime.utc_now(), revoked_by_id: by_user_id)
  end

  def delete(%EnrollmentKey{} = key) do
    change(key, deleted_at: DateTime.utc_now())
  end
end

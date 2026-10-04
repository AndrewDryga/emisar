defmodule Emisar.Fixtures.ApiKeys do
  @moduledoc """
  API key test fixtures. Use via `alias Emisar.Fixtures` then
  `Fixtures.ApiKeys.create_api_key/1`.
  """

  alias Emisar.Accounts.Membership
  alias Emisar.{ApiKeys, Fixtures, Repo}
  alias Emisar.ApiKeys.DeviceGrant

  @doc "Creates an approved, unclaimed device grant for credential lifecycle tests."
  def create_approved_device_grant(subject) do
    {:ok, _device_code, _user_code, pending} =
      ApiKeys.open_device_grant(["claude-code"], %Emisar.RequestContext{})

    {:ok, grant} = ApiKeys.approve_device_grant(pending, subject)
    grant
  end

  @doc "Backdates a device grant's expiry (default: a minute ago), returning the updated row."
  def backdate_device_grant_expiry(%DeviceGrant{} = grant, expires_at \\ nil) do
    expires_at = expires_at || DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, updated} = grant |> Ecto.Changeset.change(expires_at: expires_at) |> Repo.update()
    updated
  end

  @doc "Backdates a device grant's inserted_at (for retention sweeps), returning the updated row."
  def backdate_device_grant_inserted_at(%DeviceGrant{} = grant, inserted_at) do
    {:ok, updated} = grant |> Ecto.Changeset.change(inserted_at: inserted_at) |> Repo.update()
    updated
  end

  @doc """
  Creates an API key. Returns `{raw, key}`. `:created_by_membership_id` names
  the exact Member minting it; by default a new owner of `:account_id` does.
  With `:issued_by_membership_id`, that Member mints it instead, for the
  service account `:created_by_membership_id` names.
  """
  def create_api_key(attrs \\ %{}) do
    attrs = Map.new(attrs)

    creator =
      case attrs[:created_by_membership_id] do
        nil ->
          account_id = attrs[:account_id] || Fixtures.Accounts.create_account().id
          Fixtures.Memberships.create_membership(account_id: account_id, role: "owner")

        membership_id ->
          Repo.get!(Membership, membership_id)
      end

    create_attrs =
      %{
        name: attrs[:name] || "key-#{Fixtures.Random.unique_int()}",
        description: attrs[:description],
        kind: attrs[:kind] || :mcp,
        expires_at: attrs[:expires_at]
      }

    {:ok, raw, key} =
      case attrs[:issued_by_membership_id] do
        nil ->
          subject = Fixtures.Subjects.subject_for(creator)
          ApiKeys.create_key(create_attrs, subject)

        issuer_id ->
          issuer = Repo.get!(Membership, issuer_id)
          subject = Fixtures.Subjects.subject_for(issuer)
          ApiKeys.create_service_account_key(creator.id, create_attrs, subject)
      end

    {raw, key}
  end

  @doc """
  Backdates a key's expiry (default: a minute ago), returning the updated row.
  Minting refuses an expiry that isn't in the future, so an already-dead key is
  arranged here rather than through `create_api_key/1`.
  """
  def backdate_api_key_expiry(%ApiKeys.ApiKey{} = key, expires_at \\ nil) do
    expires_at = expires_at || DateTime.add(DateTime.utc_now(), -60, :second)
    key |> Ecto.Changeset.change(expires_at: expires_at) |> Repo.update!()
  end

  def mark_revoked(%ApiKeys.ApiKey{} = key),
    do: key |> ApiKeys.ApiKey.Changeset.revoke(key.created_by_membership_id) |> Repo.update!()

  def mark_deleted(%ApiKeys.ApiKey{} = key),
    do: key |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update!()

  def mark_auto_generated(%ApiKeys.ApiKey{} = key),
    do: key |> Ecto.Changeset.change(auto_generated_at: DateTime.utc_now()) |> Repo.update!()

  @doc """
  Backdates a key's `inserted_at`, so a test can age a rotation lineage past the
  auto-rotation ceiling. Returns the updated row.
  """
  def backdate_api_key_inserted_at(%ApiKeys.ApiKey{} = key, inserted_at) do
    key |> Ecto.Changeset.change(inserted_at: inserted_at) |> Repo.update!()
  end

  @doc """
  Stamps a key as having authenticated an MCP call (`last_used_at` set) —
  the observed-use transition a real client's first call performs.
  """
  def mark_used(%ApiKeys.ApiKey{} = key) do
    key |> ApiKeys.ApiKey.Changeset.usage() |> Repo.update!()
  end

  def mark_rotation_supported(%ApiKeys.ApiKey{} = key),
    do: key |> ApiKeys.ApiKey.Changeset.record_rotation_support(true) |> Repo.update!()

  @doc """
  Backdates a key's usage stamp past the rewrite window, so a test can prove
  the next authenticated call re-stamps it (a fresh stamp is left alone).
  """
  def backdate_api_key_usage(%ApiKeys.ApiKey{} = key, last_used_at \\ nil) do
    last_used_at = last_used_at || DateTime.add(DateTime.utc_now(), -120, :second)
    key |> Ecto.Changeset.change(last_used_at: last_used_at) |> Repo.update!()
  end

  @doc """
  Forges a rotation back-link directly on the row — the production paths can
  only mint same-account links, so tests use this to prove the retirement
  sweep's own scoping holds even against a corrupted link.
  """
  def force_replaces(%ApiKeys.ApiKey{} = key, replaced_id) do
    key |> Ecto.Changeset.change(replaces_id: replaced_id) |> Repo.update!()
  end

  @doc "Forges an unbound row so auth tests cover fail-closed legacy data."
  def force_membership_unbound(%ApiKeys.ApiKey{} = key) do
    key |> Ecto.Changeset.change(created_by_membership_id: nil) |> Repo.update!()
  end
end

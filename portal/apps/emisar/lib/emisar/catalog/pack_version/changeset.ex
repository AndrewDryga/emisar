defmodule Emisar.Catalog.PackVersion.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.PackVersion

  @insert_fields ~w(account_id pack_id version hash pending_hash trust_state
                    pinned_at pinned_by_id first_seen_at last_seen_at)a

  @doc "Insert with explicit trust state (e.g. auto-pin on first sight)."
  def insert(attrs) do
    %PackVersion{}
    |> cast(attrs, @insert_fields)
    |> validate_required([:account_id, :pack_id, :version, :first_seen_at, :last_seen_at])
    |> unique_constraint([:account_id, :pack_id, :version])
  end

  @doc "Refresh last_seen_at while keeping trust untouched."
  def touch(%PackVersion{} = pack_version, now) do
    pack_version
    |> change(last_seen_at: now)
  end

  @doc """
  A runner reported a different hash than the trusted one. Park it as
  pending; dispatch will refuse until a human decides. Idempotent —
  re-applying the same pending_hash is a no-op.
  """
  def mark_pending(%PackVersion{} = pack_version, pending_hash, now) do
    pack_version
    |> change(%{
      pending_hash: pending_hash,
      trust_state: :pending,
      last_seen_at: now
    })
  end

  @doc "Adopt pending_hash as the trusted hash. Audited via Audit.log."
  def trust(%PackVersion{} = pack_version, %{} = subject) do
    pack_version
    |> change(%{
      hash: pack_version.pending_hash,
      pending_hash: nil,
      trust_state: :trusted,
      pinned_at: DateTime.utc_now(),
      pinned_by_id: subject_user_id(subject)
    })
    |> validate_required([:hash])
  end

  @doc "Discard pending_hash; keep the trusted hash unchanged."
  def reject(%PackVersion{} = pack_version, %{} = subject) do
    pack_version
    |> change(%{
      pending_hash: nil,
      trust_state: :trusted,
      pinned_at: DateTime.utc_now(),
      pinned_by_id: subject_user_id(subject)
    })
  end

  defp subject_user_id(%Emisar.Auth.Subject{actor: %{id: user_id, type: :user}}), do: user_id
  defp subject_user_id(_), do: nil
end

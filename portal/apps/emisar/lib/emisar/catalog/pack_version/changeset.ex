defmodule Emisar.Catalog.PackVersion.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.PackVersion

  @insert_fields ~w(account_id pack_id version hash pending_hash trust_state
                    trusted_manifest first_seen_at last_seen_at)a
  @max_pack_id_length 128
  @pack_id_format ~r/\A[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)*\z/
  @max_pack_version_length 64
  @pack_version_format ~r/\A[A-Za-z0-9][A-Za-z0-9.+-]*\z/
  @max_pack_hash_length 71
  @pack_hash_format ~r/\Asha256:[0-9a-f]{64}\z/

  @doc "Insert with explicit trust state (e.g. auto-pin on first sight)."
  def insert(attrs) do
    %PackVersion{}
    |> cast(attrs, @insert_fields)
    |> validate_required([:account_id, :pack_id, :version, :first_seen_at, :last_seen_at])
    |> validate_length(:pack_id, max: @max_pack_id_length)
    |> validate_format(:pack_id, @pack_id_format)
    |> validate_length(:version, max: @max_pack_version_length)
    |> validate_format(:version, @pack_version_format)
    |> validate_hashes()
    |> unique_constraint([:account_id, :pack_id, :version])
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
    # A pending row with no bytes to review is undecidable: Trust and Reject
    # both refuse it forever, dispatch stays closed, and only a destructive
    # delete clears it. Fail the write instead.
    |> validate_required([:pending_hash])
    |> validate_hashes()
  end

  @doc "Restore a published complete manifest on an already trusted hash."
  def restore_baseline_manifest(%PackVersion{} = pack_version, %{} = trusted_manifest) do
    change(pack_version, trusted_manifest: trusted_manifest)
  end

  @doc """
  Adopt pending_hash as the trusted hash and snapshot its complete, versioned
  action manifest, so a later re-advertised hash can be diffed against every
  execution/model-facing descriptor field. Audited via Audit.log.
  """
  def trust(%PackVersion{} = pack_version, %{} = trusted_manifest) do
    pack_version
    |> change(%{
      hash: pack_version.pending_hash,
      pending_hash: nil,
      trust_state: :trusted,
      trusted_manifest: trusted_manifest
    })
    |> validate_required([:hash])
    |> validate_hashes()
  end

  @doc """
  Stamp the deliberate admin override of this version's retirement —
  trusting a retired version anyway. Accepts a `%PackVersion{}` (the
  standalone `override_pack_retirement` on an already-trusted row) or a
  changeset (composed onto `trust/2` when the version being trusted is
  retired), so both entry points write the same override in one changeset.
  """
  def override_retirement(pack_version_or_changeset, overridden_by_id) do
    pack_version_or_changeset
    |> change(%{
      retirement_overridden_at: DateTime.utc_now(),
      retirement_overridden_by_id: overridden_by_id
    })
    |> validate_required([:retirement_overridden_by_id])
  end

  @doc "Discard pending_hash; revert to the previously-trusted hash."
  def reject(%PackVersion{} = pack_version) do
    pack_version
    |> change(%{
      pending_hash: nil,
      trust_state: :trusted
    })
  end

  @doc """
  Reject a never-trusted pack (no prior `hash` to fall back to). Marks the row
  `:rejected` — the row PERSISTS so the `runner_actions` referencing this
  version resolve to an explicit untrusted decision and dispatch fails closed
  (it is NOT deleted, which would leave a missing row the gate read as
  trusted). The refused bytes stay in `pending_hash` so `judge_drift` parks a
  same-hash re-advertisement quietly instead of re-opening the review; only a
  genuinely new hash re-surfaces as `:pending`.
  """
  def reject_untrusted(%PackVersion{} = pack_version) do
    change(pack_version, trust_state: :rejected)
  end

  @doc """
  Revoke an operator's trust in a version (an accidental Trust, or silencing a
  retired version's warning). The row moves to `:rejected` keeping `hash` +
  `trusted_manifest` on record — a same-hash re-advertisement stays quiet and
  `restore_trust/1` can re-adopt it later — and any retirement override is
  cleared so a later re-trust must re-decide it deliberately.
  """
  def revoke_trust(%PackVersion{} = pack_version) do
    pack_version
    |> change(%{
      trust_state: :rejected,
      retirement_overridden_at: nil,
      retirement_overridden_by_id: nil
    })
  end

  @doc """
  Restore trust in a revoked row that still carries its recorded `hash` +
  `trusted_manifest` (the fix-admin-mistake inverse of `revoke_trust/1`).
  A rejected row with a `pending_hash` goes through `trust/2` instead.
  """
  def restore_trust(%PackVersion{} = pack_version) do
    pack_version
    |> change(trust_state: :trusted)
    |> validate_required([:hash])
  end

  defp validate_hashes(changeset) do
    changeset
    |> validate_length(:hash, max: @max_pack_hash_length)
    |> validate_format(:hash, @pack_hash_format)
    |> validate_length(:pending_hash, max: @max_pack_hash_length)
    |> validate_format(:pending_hash, @pack_hash_format)
  end
end

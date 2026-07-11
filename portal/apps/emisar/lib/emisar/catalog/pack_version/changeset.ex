defmodule Emisar.Catalog.PackVersion.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.PackVersion

  @insert_fields ~w(account_id pack_id version hash pending_hash trust_state
                    first_seen_at last_seen_at)a

  @doc "Insert with explicit trust state (e.g. auto-pin on first sight)."
  def insert(attrs) do
    %PackVersion{}
    |> cast(attrs, @insert_fields)
    |> validate_required([:account_id, :pack_id, :version, :first_seen_at, :last_seen_at])
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
  end

  @doc """
  Adopt pending_hash as the trusted hash and snapshot the action set
  (`action_id => {risk, kind}`) trusted alongside it, so a later
  re-advertised hash can be diffed against it. Audited via Audit.log.
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
  `:rejected` and clears the pending hash — the row PERSISTS so the
  `runner_actions` referencing this version resolve to an explicit untrusted
  decision and dispatch fails closed (it is NOT deleted, which would leave a
  missing row the gate read as trusted).
  """
  def reject_untrusted(%PackVersion{} = pack_version) do
    pack_version
    |> change(%{
      pending_hash: nil,
      trust_state: :rejected
    })
  end
end

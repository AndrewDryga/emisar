defmodule Emisar.Catalog.PackVersion do
  @moduledoc """
  One row per `(account_id, pack_id, version)` the fleet has
  advertised. Stores the **trusted** hash (what dispatch authorizes
  against) plus, optionally, a **pending** hash a runner reported
  later that hasn't been operator-approved yet.

  Trust states:

    * `"trusted"` — `hash` is the canonical hash. Dispatch allowed.
    * `"pending"` — `pending_hash` was advertised after `hash` was
      pinned (or first-sight diverged from the shipped library
      baseline). Dispatch refuses runs for this pack/version until
      a user clicks Trust (adopt `pending_hash`) or Reject (clear).

    * `"rejected"` — an operator refused this version: a never-trusted
      pack they rejected (the refused bytes stay in `pending_hash`), or a
      previously-trusted version whose trust they revoked (`hash` +
      `trusted_manifest` stay on record). The row PERSISTS in this state
      rather than being deleted, so the `runner_actions` referencing this
      `(pack_id, version)` resolve to an explicit untrusted decision and
      dispatch fails CLOSED. Re-advertisements of the already-refused hash
      stay quiet; only a genuinely new hash flips it back to `:pending`
      for another review. Trusting the row again (adopt the refused hash,
      or restore the revoked one) is always available. Rejecting the new
      hash on a revoked row returns it to `:rejected` with the revoked
      `hash` still on record (`trust_revoked_at`); it never reinstates it.

  `trusted_manifest` is a versioned snapshot of the complete bounded action
  descriptors for the exact trusted hash. A re-advertised hash can therefore
  be diffed before re-trust. Historical sparse or null manifests remain
  incomplete for static/MCP reads; they are never rebuilt from live runner
  prose.
  """
  use Emisar, :schema

  schema "catalog_pack_versions" do
    field :pack_id, :string
    field :version, :string
    field :hash, :string
    field :pending_hash, :string
    field :trust_state, Ecto.Enum, values: [:trusted, :pending, :rejected], default: :trusted
    field :trusted_manifest, :map

    # Set when an operator revokes trust in the recorded `hash`, cleared when
    # trust is adopted or restored. A revoked row that a new hash re-opens for
    # review is `:pending` like any drift, so this is what tells Reject to
    # return it to `:rejected` instead of reinstating the revoked hash.
    field :trust_revoked_at, :utc_datetime_usec
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    # Set when an admin explicitly re-trusts a RETIRED version (the deliberate
    # override that lets it dispatch again). Null means "no override".
    field :retirement_overridden_at, :utc_datetime_usec
    belongs_to :retirement_overridden_by_membership, Emisar.Accounts.Membership
    field :retirement_override_label, :string, virtual: true

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]

    timestamps()
  end
end

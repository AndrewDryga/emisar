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

    * `"rejected"` — an operator rejected a never-trusted pack (no prior
      `hash` to fall back to). The row PERSISTS in this state rather than
      being deleted, so the `runner_actions` referencing this
      `(pack_id, version)` resolve to an explicit untrusted decision and
      dispatch fails CLOSED. A later runner advertisement of a fresh hash
      flips it back to `:pending` for another review.

  `trusted_manifest` is a versioned snapshot of the complete bounded action
  descriptors for the exact trusted hash. A re-advertised hash can therefore
  be diffed before re-trust. Historical sparse or null manifests remain
  incomplete for static/MCP reads; they are never rebuilt from live runner
  prose.
  """
  use Emisar, :schema

  schema "pack_versions" do
    field :pack_id, :string
    field :version, :string
    field :hash, :string
    field :pending_hash, :string
    field :trust_state, Ecto.Enum, values: [:trusted, :pending, :rejected], default: :trusted
    field :trusted_manifest, :map
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    # Set when an admin explicitly re-trusts a RETIRED version (the deliberate
    # override that lets it dispatch again). Null means "no override".
    field :retirement_overridden_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :retirement_overridden_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end

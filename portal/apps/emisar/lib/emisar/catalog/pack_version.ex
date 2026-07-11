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

  `trusted_manifest` snapshots the action set (`action_id => {risk, kind}`)
  as it was when this hash was trusted, so a re-advertised hash that flips
  the row back to `:pending` can be DIFFED against it — surfacing an added
  `critical` action before the operator re-trusts. Null until the first
  Trust (and for rows trusted before this feature); null means "no diff".
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

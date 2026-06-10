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

  `pinned_at` / `pinned_by_id` record the most recent trust decision.
  System pins (auto-trust on library match, TOFU on unknown pack) leave
  `pinned_by_id` null.
  """
  use Emisar, :schema

  schema "pack_versions" do
    field :pack_id, :string
    field :version, :string
    field :hash, :string
    field :pending_hash, :string
    field :trust_state, Ecto.Enum, values: [:trusted, :pending], default: :trusted
    field :pinned_at, :utc_datetime_usec
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :pinned_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end

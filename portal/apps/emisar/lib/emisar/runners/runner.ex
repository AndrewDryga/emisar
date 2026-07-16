defmodule Emisar.Runners.Runner do
  @moduledoc """
  A single emisar binary running on a host. The DB row holds the most
  recent runner_state advertisement plus durable connect/disconnect
  history; live connection state (online, action_load, last heartbeat)
  is Phoenix.Presence, surfaced here as virtual fields.
  """
  use Emisar, :schema

  schema "runners" do
    field :name, :string
    field :external_id, :string
    field :group, :string
    field :hostname, :string
    field :labels, :map, default: %{}
    field :runner_version, :string
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_disconnect_reason, :string
    field :connection_generation, :integer, default: 0
    field :connection_lease_id, Ecto.UUID
    field :connection_lease_expires_at, :utc_datetime_usec
    field :packs, :map, default: %{}
    # Packs the runner's loader skipped at boot (unparseable/invalid on disk),
    # advertised on runner_state: [%{"pack" => name, "reason" => text}],
    # normalized + bounded at ingest.
    field :degraded_packs, {:array, :map}, default: []

    # Runner-advertised: the runner verifies a client signature on every
    # dispatch and refuses unsigned ones, so the portal disables its own
    # (operator/runbook) dispatch to it — only signed MCP calls get through.
    field :enforce_signatures, :boolean, default: false

    # Runner-advertised freshness window (seconds) for a signed dispatch's
    # issued_at; lets the portal refuse an approval up front when the parked
    # signature would already be stale (the runner stays the authority). Nil
    # until a signing-enforcing runner advertises it.
    field :max_attestation_age_seconds, :integer

    # Connection state lives in `Emisar.Runners.Presence`, not the DB.
    # These virtuals are filled from presence metadata by the context
    # read functions; see `Emisar.Runners.connection_state/1`.
    field :online?, :boolean, virtual: true, default: false
    field :action_load, :integer, virtual: true, default: 0
    field :last_heartbeat_at, :utc_datetime_usec, virtual: true

    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :bootstrap_enrollment_key, Emisar.Runners.EnrollmentKey, where: [deleted_at: nil]

    has_many :tokens, Emisar.Runners.Token
    has_many :actions, Emisar.Catalog.RunnerAction
    has_many :runs, Emisar.Runs.ActionRun

    timestamps()
  end
end

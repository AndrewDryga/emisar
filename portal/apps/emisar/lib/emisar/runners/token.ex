defmodule Emisar.Runners.Token do
  @moduledoc """
  Per-runner token, minted at first registration and rotated from there. The
  runner persists this at `${data_dir}/token` and presents it on every
  reconnect. Enrollment keys are one-shot bootstraps; tokens are the durable
  credential.

  A token carries an `expires_at`, refused by `Runners.verify_runner_token/1`
  once it passes, so a leak nobody discovers still stops working. The runner
  exchanges a live token for a successor over `POST /runner/token/refresh` — no
  host access, no enrollment key — and the outgoing one keeps working for a
  grace window after its successor is minted, so a runner that fails to persist
  the successor still has a way in on its next connect.
  """
  use Emisar, :schema

  schema "runner_tokens" do
    field :token_prefix, :string
    field :token_hash, :binary, redact: true
    field :issued_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    # NULL means never expires. Every token minted before rotation shipped is
    # NULL and stays that way, so enforcement can never strand a runner that has
    # no refresh path. See Runners.refresh_runner_token/1.
    field :expires_at, :utc_datetime_usec

    belongs_to :runner, Emisar.Runners.Runner, where: [deleted_at: nil]
    belongs_to :issued_via_key, Emisar.Runners.EnrollmentKey, where: [deleted_at: nil]

    timestamps()
  end
end

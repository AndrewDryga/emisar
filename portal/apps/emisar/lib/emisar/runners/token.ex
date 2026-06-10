defmodule Emisar.Runners.Token do
  @moduledoc """
  Per-runner long-lived token, minted at first registration. The
  runner persists this at `${data_dir}/token` and presents it on every
  reconnect. Auth keys are one-shot bootstraps; tokens are the durable
  credential.
  """
  use Emisar, :schema

  schema "runner_tokens" do
    field :token_prefix, :string
    field :token_hash, :binary, redact: true
    field :issued_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :runner, Emisar.Runners.Runner
    belongs_to :issued_via_key, Emisar.Runners.AuthKey

    timestamps()
  end

  def usable?(%__MODULE__{revoked_at: nil}), do: true
  def usable?(_), do: false
end

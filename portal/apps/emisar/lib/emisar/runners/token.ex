defmodule Emisar.Runners.Token do
  @moduledoc """
  Per-runner long-lived token, minted at first registration. The runner
  persists this at `${data_dir}/token` and presents it on every
  reconnect. Auth keys are one-shot bootstraps; tokens are the
  durable credential.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runner_tokens" do
    field :token_prefix, :string
    field :token_hash, :binary, redact: true
    field :issued_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :runner, Emisar.Runners.Runner
    belongs_to :issued_via_key, Emisar.Runners.AuthKey

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:runner_id, :token_prefix, :token_hash, :issued_via_key_id, :issued_at])
    |> validate_required([:runner_id, :token_prefix, :token_hash, :issued_at])
  end

  def usage_changeset(token, at \\ DateTime.utc_now()) do
    change(token, last_used_at: DateTime.truncate(at, :microsecond))
  end

  def revoke_changeset(token, at \\ DateTime.utc_now()) do
    change(token, revoked_at: DateTime.truncate(at, :microsecond))
  end

  def usable?(%__MODULE__{revoked_at: nil}), do: true
  def usable?(_), do: false
end

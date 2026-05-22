defmodule Emisar.Runners.Runner do
  @moduledoc """
  A single emisar binary running on a host. State here is the most
  recent agent_state advertisement plus heartbeat-driven liveness.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending connected disconnected disabled)

  schema "runners" do
    field :name, :string
    field :external_id, :string
    field :group, :string
    field :hostname, :string
    field :labels, :map, default: %{}
    field :runner_version, :string
    field :status, :string, default: "pending"
    field :last_connected_at, :utc_datetime_usec
    field :last_disconnected_at, :utc_datetime_usec
    field :last_disconnect_reason, :string
    field :last_heartbeat_at, :utc_datetime_usec
    field :action_load, :integer, default: 0
    field :packs, :map, default: %{}
    field :bootstrap_auth_key_id, Ecto.UUID
    field :disabled_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account

    has_many :tokens, Emisar.Runners.Token
    has_many :actions, Emisar.Catalog.RunnerAction
    has_many :runs, Emisar.Runs.ActionRun

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(runner, attrs) do
    runner
    |> cast(attrs, [:account_id, :name, :external_id, :group, :hostname, :labels, :runner_version, :bootstrap_auth_key_id])
    |> validate_required([:account_id, :name, :group])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:group, min: 1, max: 80)
    |> unique_constraint([:account_id, :external_id])
  end

  def manual_create_changeset(runner, attrs) do
    runner
    |> cast(attrs, [:account_id, :name, :group, :labels])
    |> validate_required([:account_id, :name, :group])
    |> validate_length(:name, min: 1, max: 80)
  end

  def state_changeset(runner, attrs) do
    runner
    |> cast(attrs, [:hostname, :labels, :runner_version, :packs, :external_id])
  end

  def connected_changeset(runner, _payload \\ %{}) do
    change(runner,
      status: "connected",
      last_connected_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      last_disconnect_reason: nil
    )
  end

  def disconnected_changeset(runner, reason \\ nil) do
    change(runner,
      status: "disconnected",
      last_disconnected_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      last_disconnect_reason: reason
    )
  end

  def heartbeat_changeset(runner, action_load) do
    change(runner,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      action_load: action_load || runner.action_load
    )
  end

  def statuses, do: @statuses
end

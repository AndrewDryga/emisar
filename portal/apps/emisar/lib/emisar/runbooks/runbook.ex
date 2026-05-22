defmodule Emisar.Runbooks.Runbook do
  @moduledoc """
  Cloud-side workflow composed of action calls. The runner never sees a
  runbook — cloud expands it into individual `run_action` messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft published archived)

  schema "runbooks" do
    field :name, :string
    field :slug, :string
    field :title, :string
    field :description, :string
    field :version, :integer, default: 1
    field :status, :string, default: "draft"
    field :definition, :map
    field :archived_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account
    belongs_to :created_by, Emisar.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(runbook, attrs) do
    runbook
    |> cast(attrs, [:account_id, :name, :slug, :title, :description, :status, :definition, :created_by_id, :version])
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :slug, :version])
  end

  def statuses, do: @statuses
end

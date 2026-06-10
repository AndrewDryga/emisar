defmodule Emisar.Runbooks.Runbook do
  @moduledoc """
  Cloud-side workflow composed of action calls. The runner never sees a
  runbook — cloud expands it into individual `run_action` messages.
  """
  use Emisar, :schema

  schema "runbooks" do
    field :name, :string
    field :slug, :string
    field :title, :string
    field :description, :string
    field :version, :integer, default: 1
    field :status, :string, default: "draft"
    field :definition, :map
    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :created_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end

  def statuses, do: Emisar.Runbooks.Runbook.Changeset.statuses()
end

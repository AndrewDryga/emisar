defmodule Emisar.Runbooks.Runbook do
  @moduledoc """
  Cloud-side workflow composed of action calls. The runner never sees a
  runbook — cloud expands it into individual `run_action` messages.

  One row per runbook. `definition` is what is live and `live_version` counts
  publishes (both null until the first release); `draft_definition` holds the
  single unpublished change, null when there is none.
  """
  use Emisar, :schema

  schema "runbooks" do
    field :name, :string
    field :slug, :string
    field :title, :string
    field :description, :string

    field :live_version, :integer
    field :definition, :map
    field :draft_definition, :map

    field :deleted_at, :utc_datetime_usec

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :created_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end

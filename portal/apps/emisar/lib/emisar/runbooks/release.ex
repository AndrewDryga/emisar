defmodule Emisar.Runbooks.Release do
  @moduledoc """
  One publish of one runbook — the append-only record of what the approved
  procedure was between two points in time.

  Written once when a draft is published and never mutated: the runbook row
  moves on, this does not.
  """
  use Emisar, :schema

  schema "runbook_releases" do
    field :version, :integer
    field :title, :string
    field :description, :string
    field :definition, :map
    field :definition_sha256, :string

    belongs_to :account, Emisar.Accounts.Account, where: [deleted_at: nil]
    belongs_to :runbook, Emisar.Runbooks.Runbook, where: [deleted_at: nil]
    belongs_to :published_by, Emisar.Users.User, where: [deleted_at: nil]

    timestamps()
  end
end

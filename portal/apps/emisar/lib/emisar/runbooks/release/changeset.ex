defmodule Emisar.Runbooks.Release.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.Release

  @fields ~w[account_id runbook_id version title description definition definition_sha256
             published_by_id]a

  @doc "Mints release `version` of one runbook. The only transition — a release never changes."
  def create(attrs) do
    %Release{}
    |> cast(attrs, @fields)
    |> validate_required([
      :account_id,
      :runbook_id,
      :version,
      :title,
      :definition,
      :definition_sha256
    ])
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:definition_sha256, is: 64)
    |> unique_constraint([:runbook_id, :version])
  end
end

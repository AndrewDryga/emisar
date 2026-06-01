defmodule Emisar.Runbooks.Runbook.Changeset do
  use Emisar, :changeset
  alias Emisar.Runbooks.Runbook

  @statuses ~w(draft published)
  @fields ~w[name slug title description status definition version]a

  def create(account_id, user_id, attrs) do
    %Runbook{}
    |> cast(attrs, @fields)
    |> put_change(:account_id, account_id)
    |> put_change(:created_by_id, user_id)
    |> changeset()
  end

  def update(%Runbook{} = runbook, attrs) do
    runbook |> cast(attrs, @fields) |> changeset()
  end

  def delete(%Runbook{} = runbook),
    do: change(runbook, deleted_at: now())

  def statuses, do: @statuses

  defp changeset(cs) do
    cs
    |> validate_required([:account_id, :name, :slug, :title, :definition])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:slug, ~r/^[a-z][a-z0-9_-]{0,79}$/)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:account_id, :slug, :version])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

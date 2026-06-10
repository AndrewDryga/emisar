defmodule Emisar.Catalog.RunnerAction.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.RunnerAction

  @risks ~w(low medium high critical)
  @kinds ~w(exec script)

  @fields ~w[
    account_id runner_id action_id pack_id pack_version title kind risk
    description side_effects args_schema limits output examples
    first_seen_at last_seen_at
  ]a

  # Re-advertisement of an already-seen action: refresh every field but the
  # immutable first_seen_at. Same validations as insert so an invalid
  # kind/risk in a later advertisement can't force-write past the whitelist.
  @update_fields @fields -- [:first_seen_at]

  def upsert(attrs) do
    %RunnerAction{}
    |> cast(attrs, @fields)
    |> shared()
  end

  def update(%RunnerAction{} = action, attrs) do
    action
    |> cast(attrs, @update_fields)
    |> shared()
  end

  def risks, do: @risks
  def kinds, do: @kinds

  defp shared(changeset) do
    changeset
    |> validate_required([:account_id, :runner_id, :action_id, :title, :kind, :risk])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:risk, @risks)
    |> unique_constraint([:runner_id, :action_id])
  end
end

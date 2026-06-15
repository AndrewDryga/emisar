defmodule Emisar.Catalog.RunnerAction.Changeset do
  use Emisar, :changeset
  alias Emisar.Catalog.RunnerAction

  @fields ~w[
    account_id runner_id action_id pack_id pack_version title kind risk
    description side_effects args_schema limits output examples
    first_seen_at last_seen_at
  ]a

  # Re-advertisement of an already-seen action: refresh every field but the
  # immutable first_seen_at. Same validations as insert so an invalid
  # kind/risk in a later advertisement can't force-write past the whitelist.
  @update_fields @fields -- [:first_seen_at]

  # Generous caps on the runner-advertised descriptor. A frame is bounded to
  # ~1 MB by the socket, but a hostile authenticated runner could advertise
  # many fat actions to grow its account's catalog (and every UI/MCP render of
  # it). `title` is a short label (255); a `description` is prose (4 KB). The
  # jsonb/array fields (args_schema, limits, output, examples, side_effects)
  # are structured data a real pack keeps to a few KB, so 64 KB serialized each
  # is well above any honest descriptor while bounding the gross-abuse row.
  @max_title_length 255
  @max_description_length 4_096
  @max_json_bytes 65_536
  @json_fields ~w[args_schema limits output examples side_effects]a

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

  defp shared(changeset) do
    changeset
    |> validate_required([:account_id, :runner_id, :action_id, :title, :kind, :risk])
    |> validate_length(:title, max: @max_title_length)
    |> validate_length(:description, max: @max_description_length)
    |> validate_json_sizes()
    |> unique_constraint([:runner_id, :action_id])
  end

  defp validate_json_sizes(changeset) do
    Enum.reduce(@json_fields, changeset, &validate_json_size(&2, &1))
  end

  defp validate_json_size(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        case Jason.encode(value) do
          {:ok, json} when byte_size(json) > @max_json_bytes ->
            add_error(changeset, field, "is too large (max #{@max_json_bytes} bytes serialized)")

          _ ->
            changeset
        end
    end
  end
end

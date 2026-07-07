defmodule Emisar.Runs.RunEvent.Changeset do
  use Emisar, :changeset
  alias Emisar.Repo.Changeset, as: RepoChangeset
  alias Emisar.Runs.RunEvent

  # Runner progress chunks are already byte-limited by action output settings,
  # but the cloud still treats runner-origin JSON as hostile. This caps one
  # persisted event row so a compromised runner cannot insert multi-MB payloads.
  @max_payload_bytes 262_144
  @max_stream_length 32

  def create(attrs) do
    %RunEvent{}
    |> cast(attrs, [:run_id, :account_id, :seq, :kind, :stream, :payload])
    |> validate_required([:run_id, :account_id, :seq, :kind])
    |> validate_length(:stream, max: @max_stream_length)
    |> RepoChangeset.validate_json_size(:payload, @max_payload_bytes)
    |> unique_constraint([:run_id, :seq])
  end
end

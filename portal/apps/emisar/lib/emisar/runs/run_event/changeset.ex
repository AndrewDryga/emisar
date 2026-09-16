defmodule Emisar.Runs.RunEvent.Changeset do
  use Emisar, :changeset
  alias Emisar.Repo.Changeset, as: RepoChangeset
  alias Emisar.Runs.RunEvent
  alias Emisar.SafeText

  # Runner progress chunks are already byte-limited by action output settings,
  # but the cloud still treats runner-origin JSON as hostile. This caps one
  # persisted event row so a compromised runner cannot insert multi-MB payloads.
  @max_payload_bytes 262_144
  @max_stream_length 32
  @max_db_integer 2_147_483_647

  def create(attrs) do
    %RunEvent{}
    |> cast(attrs, [:run_id, :account_id, :seq, :kind, :stream, :payload])
    |> validate_required([:run_id, :account_id, :seq, :kind])
    # A chunk is stored as the runner emitted it, so nothing here strips
    # control bytes — except NUL, which Postgres refuses in text and jsonb with
    # a raise the socket cannot turn into a dropped chunk. An honest `tail` of
    # a NUL-padded log carries one; it lands as U+FFFD, like invalid UTF-8.
    |> update_change(:stream, &SafeText.replace_nul/1)
    |> update_change(:payload, &replace_nul_in_json/1)
    # Runner seq is 1-based (first chunk is seq=1); seq <= 0 is malformed.
    # Mirrored by the DB CHECK so a bypassing writer can't persist it either.
    # The upper bound is the int4 column's: Elixir integers are arbitrary
    # precision, so an unbounded seq built a VALID changeset and then raised in
    # Postgrex — which is not the {:error, changeset} the socket handles, so it
    # crashed the connection into a reconnect loop.
    |> validate_number(:seq,
      greater_than: 0,
      less_than_or_equal_to: @max_db_integer
    )
    |> validate_length(:stream, max: @max_stream_length)
    |> RepoChangeset.validate_json_size(:payload, @max_payload_bytes)
    |> unique_constraint([:run_id, :seq])
    |> check_constraint(:seq,
      name: :action_run_events_seq_positive,
      message: "must be greater than 0"
    )
  end

  defp replace_nul_in_json(%{} = map),
    do: Map.new(map, fn {key, value} -> {key, replace_nul_in_json(value)} end)

  defp replace_nul_in_json(list) when is_list(list), do: Enum.map(list, &replace_nul_in_json/1)
  defp replace_nul_in_json(value) when is_binary(value), do: SafeText.replace_nul(value)
  defp replace_nul_in_json(value), do: value
end

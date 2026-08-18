defmodule Emisar.Runs.RunEventTest do
  use ExUnit.Case, async: true
  import Emisar.DataCase, only: [errors_on: 1]
  alias Emisar.Runs.RunEvent

  defp create_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        run_id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        seq: 1,
        kind: "progress",
        stream: "stdout",
        payload: %{"chunk" => "line 1"}
      },
      attrs
    )
  end

  describe "create/1 size caps" do
    test "accepts a normal progress event" do
      changeset = RunEvent.Changeset.create(create_attrs())

      assert changeset.valid?
    end

    test "rejects an oversized payload before inserting the jsonb row" do
      payload = %{"chunk" => String.duplicate("x", 262_145)}
      changeset = RunEvent.Changeset.create(create_attrs(%{payload: payload}))

      refute changeset.valid?
      assert errors_on(changeset).payload == ["is too large (max 262144 bytes serialized)"]
    end

    test "rejects an oversized stream label before the DB string column does" do
      changeset = RunEvent.Changeset.create(create_attrs(%{stream: String.duplicate("x", 33)}))

      refute changeset.valid?
      assert errors_on(changeset).stream == ["should be at most 32 character(s)"]
    end

    test "rejects a non-positive seq from a hostile runner" do
      # Runner seq is 1-based; 0 and negatives are malformed and rejected before
      # the row (and the DB CHECK) ever see them.
      for bad_seq <- [0, -1] do
        changeset = RunEvent.Changeset.create(create_attrs(%{seq: bad_seq}))

        refute changeset.valid?
        assert errors_on(changeset).seq == ["must be greater than 0"]
      end
    end
  end
end

defmodule Emisar.Runs.RunEventTest do
  use ExUnit.Case, async: true
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
      assert Keyword.has_key?(changeset.errors, :payload)
    end

    test "rejects an oversized stream label before the DB string column does" do
      changeset = RunEvent.Changeset.create(create_attrs(%{stream: String.duplicate("x", 33)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :stream)
    end

    test "rejects a non-positive seq from a hostile runner" do
      # Runner seq is 1-based; 0 and negatives are malformed and rejected before
      # the row (and the DB CHECK) ever see them.
      for bad_seq <- [0, -1] do
        changeset = RunEvent.Changeset.create(create_attrs(%{seq: bad_seq}))

        refute changeset.valid?
        assert {"must be greater than %{number}", _} = changeset.errors[:seq]
      end
    end
  end
end

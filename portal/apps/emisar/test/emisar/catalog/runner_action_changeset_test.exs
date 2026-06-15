defmodule Emisar.Catalog.RunnerAction.ChangesetTest do
  use ExUnit.Case, async: true

  alias Emisar.Catalog.RunnerAction

  defp base_attrs(extra) do
    Map.merge(
      %{
        account_id: Ecto.UUID.generate(),
        runner_id: Ecto.UUID.generate(),
        action_id: "linux.uptime",
        title: "Uptime",
        kind: :exec,
        risk: :low
      },
      extra
    )
  end

  describe "upsert/1 size caps" do
    test "accepts a normal descriptor" do
      changeset =
        RunnerAction.Changeset.upsert(
          base_attrs(%{
            description: "Show how long the host has been up.",
            args_schema: %{"type" => "object", "properties" => %{}}
          })
        )

      assert changeset.valid?
    end

    test "rejects an oversized title" do
      changeset = RunnerAction.Changeset.upsert(base_attrs(%{title: String.duplicate("t", 300)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :title)
    end

    test "rejects an oversized description" do
      changeset =
        RunnerAction.Changeset.upsert(base_attrs(%{description: String.duplicate("d", 5_000)}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :description)
    end

    test "rejects an oversized args_schema" do
      huge = %{"junk" => for(i <- 1..5_000, into: %{}, do: {"k#{i}", String.duplicate("v", 32)})}

      changeset = RunnerAction.Changeset.upsert(base_attrs(%{args_schema: huge}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :args_schema)
    end
  end
end

defmodule Emisar.Catalog.ConsoleProjectionTest do
  @moduledoc """
  The Packs page's projection, tested as the pure functions it is.

  These rules used to live as private helpers inside `Emisar.Catalog`, reachable
  only through a Subject-gated read — so exercising a malformed advertisement
  meant first building an account, a runner, a pack version and a trust
  decision, and the interesting inputs (a runner whose `packs` is not a map)
  could not be produced through the domain at all.
  """
  use ExUnit.Case, async: true
  alias Emisar.Catalog.ConsoleProjection

  defp runner(id, packs), do: %{id: id, name: "host-#{id}", group: "default", packs: packs}

  describe "advertised_pack_ref/1" do
    test "an advertised version resolves to its exact pack ref" do
      assert ConsoleProjection.advertised_pack_ref({"nginx", %{"version" => "1.2.0"}}) ==
               {:ok, {"nginx", "1.2.0"}}
    end

    # Mirrors observe_pack/3's `info["version"] || "unknown"`, so an
    # advertisement resolves to the very row that pin created. If the two
    # spellings ever drift, the console stops finding rows it created.
    test "a missing version resolves to the same \"unknown\" the pin writes" do
      assert ConsoleProjection.advertised_pack_ref({"nginx", %{}}) ==
               {:ok, {"nginx", "unknown"}}
    end

    test "a non-string version is an error, never coerced" do
      assert ConsoleProjection.advertised_pack_ref({"nginx", %{"version" => 12}}) == :error
      assert ConsoleProjection.advertised_pack_ref({"nginx", %{"version" => %{}}}) == :error
    end

    test "a shape that is not {binary, map} at all is an error" do
      assert ConsoleProjection.advertised_pack_ref({"nginx", "1.2.0"}) == :error
      assert ConsoleProjection.advertised_pack_ref({1, %{}}) == :error
      assert ConsoleProjection.advertised_pack_ref("nginx") == :error
    end
  end

  describe "advertising_index/1" do
    test "indexes each pack ref to the runners advertising it" do
      facts = [
        runner("a", %{"nginx" => %{"version" => "1.2.0"}}),
        runner("b", %{"nginx" => %{"version" => "1.2.0"}, "redis" => %{"version" => "7.0"}})
      ]

      {index, malformed?} = ConsoleProjection.advertising_index(facts)

      refute malformed?
      assert Map.keys(index) |> Enum.sort() == [{"nginx", "1.2.0"}, {"redis", "7.0"}]
      assert length(index[{"nginx", "1.2.0"}]) == 2
      assert [%{id: "b", name: "host-b", group: "default"}] = index[{"redis", "7.0"}]
    end

    # The reason this returns a flag at all: an advertisement the console cannot
    # resolve is REPORTED, never silently dropped — a page that quietly showed
    # fewer advertisers would read as "no runner has this" rather than "we could
    # not tell".
    test "an unresolvable entry sets the malformed flag and is not indexed" do
      facts = [runner("a", %{"nginx" => %{"version" => 12}})]

      assert {index, true} = ConsoleProjection.advertising_index(facts)
      assert index == %{}
    end

    test "a runner whose packs are not a map sets the flag without losing the others" do
      facts = [
        runner("a", "not-a-map"),
        runner("b", %{"nginx" => %{"version" => "1.2.0"}})
      ]

      assert {index, true} = ConsoleProjection.advertising_index(facts)
      assert Map.keys(index) == [{"nginx", "1.2.0"}]
    end

    test "one bad entry does not suppress the good ones beside it" do
      facts = [
        runner("a", %{"nginx" => %{"version" => "1.2.0"}, "redis" => %{"version" => 0}})
      ]

      assert {index, true} = ConsoleProjection.advertising_index(facts)
      assert Map.keys(index) == [{"nginx", "1.2.0"}]
    end

    test "no runners is an empty index and nothing malformed" do
      assert ConsoleProjection.advertising_index([]) == {%{}, false}
    end
  end

  describe "risk_rank/0" do
    # Catalog folds risk through this table rather than keeping a second copy,
    # so the console and the dispatch gate cannot disagree about which tier wins.
    test "orders the four tiers, worst highest" do
      rank = ConsoleProjection.risk_rank()
      assert rank.low < rank.medium
      assert rank.medium < rank.high
      assert rank.high < rank.critical
    end
  end
end

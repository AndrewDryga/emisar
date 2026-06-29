defmodule Emisar.MapsTest do
  use ExUnit.Case, async: true
  alias Emisar.Maps

  describe "put_present/4" do
    test "puts a present value" do
      assert Maps.put_present(%{}, :a, 1) == %{a: 1}
    end

    test "skips a nil value by default, leaving the map unchanged" do
      assert Maps.put_present(%{a: 1}, :b, nil) == %{a: 1}
    end

    test "keeps an empty string by default — only nil is blank" do
      assert Maps.put_present(%{}, :a, "") == %{a: ""}
    end

    test "treats every value in :blank as absent" do
      assert Maps.put_present(%{}, :a, "", blank: [nil, ""]) == %{}
      assert Maps.put_present(%{}, :a, nil, blank: [nil, ""]) == %{}
    end

    test "puts a present value even with a custom :blank set" do
      assert Maps.put_present(%{}, :a, "x", blank: [nil, ""]) == %{a: "x"}
    end
  end
end

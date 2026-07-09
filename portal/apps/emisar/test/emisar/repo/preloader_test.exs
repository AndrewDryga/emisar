defmodule Emisar.Repo.PreloaderTest do
  use ExUnit.Case, async: true
  alias Emisar.Repo.Preloader

  defmodule VirtualPreloadQuery do
    def preloads do
      [label: fn rows -> Enum.map(rows, &Map.put(&1, :label, "computed")) end]
    end
  end

  test "applies declared virtual preloads and leaves Ecto preloads for the caller" do
    rows = [%{id: 1}, %{id: 2}]

    assert {[%{id: 1, label: "computed"}, %{id: 2, label: "computed"}], [:owner]} =
             Preloader.preload(rows, [:label, :owner], VirtualPreloadQuery)
  end

  test "applies declared virtual preloads to one result" do
    assert {%{id: 1, label: "computed"}, []} =
             Preloader.preload(%{id: 1}, [:label], VirtualPreloadQuery)
  end
end

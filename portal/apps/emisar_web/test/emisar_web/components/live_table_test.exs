defmodule EmisarWeb.LiveTableTest do
  @moduledoc """
  Pure-function coverage for `LiveTable.params_to_opts/2`. The render
  paths are exercised end-to-end via AuditLive / RunsLive — here we
  pin the params → `[filter:, page:]` translation so future filter
  shapes can't silently regress.
  """
  use ExUnit.Case, async: true

  alias Emisar.Repo.Filter
  alias EmisarWeb.LiveTable

  defp string_filter(name) do
    %Filter{name: name, type: :string, fun: fn q, _ -> {q, true} end}
  end

  defp list_filter(name, values \\ [{"a", "A"}, {"b", "B"}]) do
    %Filter{
      name: name,
      type: {:list, :string},
      values: values,
      fun: fn q, _ -> {q, true} end
    }
  end

  defp bool_filter(name) do
    %Filter{name: name, type: :boolean, fun: fn q -> {q, true} end}
  end

  describe "params_to_opts/2" do
    test "empty params → empty filter + page opts" do
      assert [filter: [], page: []] = LiveTable.params_to_opts(%{}, [])
    end

    test "ignores unknown param keys" do
      filters = [string_filter(:name)]

      assert [filter: [], page: []] =
               LiveTable.params_to_opts(%{"bogus" => "x"}, filters)
    end

    test "string filters pass through verbatim" do
      filters = [string_filter(:name)]

      assert [filter: [name: "needle"], page: []] =
               LiveTable.params_to_opts(%{"name" => "needle"}, filters)
    end

    test "list filters wrap a single value into a list" do
      filters = [list_filter(:status)]

      assert [filter: [status: ["a"]], page: []] =
               LiveTable.params_to_opts(%{"status" => "a"}, filters)
    end

    test "list filters pass through an already-list value" do
      filters = [list_filter(:status)]

      assert [filter: [status: ["a", "b"]], page: []] =
               LiveTable.params_to_opts(%{"status" => ["a", "b"]}, filters)
    end

    test "boolean filters cast \"true\" / anything-else cleanly" do
      filters = [bool_filter(:archived)]

      assert [filter: [archived: true], page: []] =
               LiveTable.params_to_opts(%{"archived" => "true"}, filters)

      assert [filter: [archived: false], page: []] =
               LiveTable.params_to_opts(%{"archived" => "false"}, filters)
    end

    test "blank string drops the filter (treated as \"not set\")" do
      filters = [string_filter(:name)]

      assert [filter: [], page: []] =
               LiveTable.params_to_opts(%{"name" => ""}, filters)
    end

    test "after cursor lands in page[:cursor]" do
      assert [filter: [], page: [cursor: "abc"]] =
               LiveTable.params_to_opts(%{"after" => "abc"}, [])
    end

    test "before cursor lands in page[:cursor] too — direction is encoded in the cursor blob" do
      assert [filter: [], page: [cursor: "xyz"]] =
               LiveTable.params_to_opts(%{"before" => "xyz"}, [])
    end

    test "after takes precedence when both are present (defensive)" do
      assert [filter: [], page: [cursor: "after-one"]] =
               LiveTable.params_to_opts(%{"after" => "after-one", "before" => "before-one"}, [])
    end

    test "filters + cursor compose into one opts list" do
      filters = [string_filter(:name), list_filter(:status)]

      opts =
        LiveTable.params_to_opts(
          %{"name" => "x", "status" => "a", "after" => "cur"},
          filters
        )

      assert Keyword.get(opts, :filter) == [name: "x", status: ["a"]]
      assert Keyword.get(opts, :page) == [cursor: "cur"]
    end
  end
end

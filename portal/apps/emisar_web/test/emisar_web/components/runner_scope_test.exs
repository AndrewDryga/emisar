defmodule EmisarWeb.RunnerScopeTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EmisarWeb.RunnerScope

  @runners [
    %{id: "r1", name: "edge-fra-01", group: "edge-web"},
    %{id: "r2", name: "edge-sfo-03", group: "edge-web"},
    %{id: "r3", name: "api-iad-02", group: "app-api"},
    %{id: "u1", name: "lonely-runner", group: nil}
  ]

  describe "tree/2" do
    test "each group carries its own runners (sorted); ungrouped runners are separate" do
      tree = RunnerScope.tree(@runners, [])

      assert Enum.map(tree.groups, & &1.name) == ["app-api", "edge-web"]

      edge = Enum.find(tree.groups, &(&1.name == "edge-web"))
      assert Enum.map(edge.runners, & &1.name) == ["edge-fra-01", "edge-sfo-03"]

      assert Enum.map(tree.ungrouped, & &1.name) == ["lonely-runner"]
    end

    test "values are prefixed group:/runner:" do
      tree = RunnerScope.tree(@runners, [])
      app = Enum.find(tree.groups, &(&1.name == "app-api"))

      assert app.value == "group:app-api"
      assert hd(app.runners).value == "runner:r3"
    end

    test "selecting a group marks it selected and its runners covered — not individually selected" do
      tree = RunnerScope.tree(@runners, ["group:edge-web"])

      edge = Enum.find(tree.groups, &(&1.name == "edge-web"))
      assert edge.selected

      for runner <- edge.runners do
        assert runner.covered
        refute runner.selected
      end

      # A runner in a DIFFERENT group is not covered.
      app = Enum.find(tree.groups, &(&1.name == "app-api"))
      refute hd(app.runners).covered
    end

    test "an individually selected runner (no group selected) is selected, not covered" do
      tree = RunnerScope.tree(@runners, ["runner:r3"])
      runner = Enum.find(tree.groups, &(&1.name == "app-api")).runners |> hd()

      assert runner.selected
      refute runner.covered
    end
  end

  describe "parse/2" do
    test "splits into groups + runner_ids, allowlisting against the real runners (IL-15)" do
      assert {:ok, parsed} =
               RunnerScope.parse(
                 ["group:app-api", "runner:r1"],
                 @runners
               )

      assert parsed == %{groups: ["app-api"], runner_ids: ["r1"]}
    end

    test "rejects unknown or malformed values instead of treating them as all runners" do
      assert {:error, :invalid} = RunnerScope.parse(["group:ghost"], @runners)
      assert {:error, :invalid} = RunnerScope.parse(["runner:from-another-account"], @runners)
      assert {:error, :invalid} = RunnerScope.parse([%{"nested" => "value"}], @runners)
      assert {:error, :invalid} = RunnerScope.parse(%{"scope" => "group:app-api"}, @runners)
    end

    test "drops a runner already covered by a selected group" do
      assert {:ok, parsed} =
               RunnerScope.parse(["group:edge-web", "runner:r1", "runner:r3"], @runners)

      assert parsed == %{groups: ["edge-web"], runner_ids: ["r3"]}
    end

    test "empty selection parses to all-runners (both empty)" do
      assert {:ok, %{groups: [], runner_ids: []}} = RunnerScope.parse([], @runners)
    end
  end

  describe "to_values/2" do
    test "round-trips a persisted {groups, runner_ids} scope to selection strings" do
      assert RunnerScope.to_values(["edge-web"], ["r3"]) == ["group:edge-web", "runner:r3"]
    end
  end

  describe "runner_scope_select/1" do
    test "renders a checkbox tree; a selected group's runners render disabled + tagged" do
      html =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          runners: @runners,
          selected: ["group:edge-web"]
        )

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(value="group:edge-web")
      assert html =~ ~s(value="runner:r1")
      # "via group" tags a runner disabled because its group is selected — the
      # covered rendering the tree drives.
      assert html =~ "via group"
    end

    test "renders the empty state when the account has no runners" do
      html =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          runners: [],
          selected: []
        )

      assert html =~ "No runners registered yet."
    end
  end
end

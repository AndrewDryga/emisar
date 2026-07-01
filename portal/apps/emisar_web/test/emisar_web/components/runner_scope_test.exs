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

  describe "options/2" do
    test "orders each group ahead of its own runners, groups then ungrouped" do
      values = @runners |> RunnerScope.options([]) |> Enum.map(& &1.value)

      assert values == [
               "group:app-api",
               "runner:r3",
               "group:edge-web",
               "runner:r1",
               "runner:r2",
               "",
               "runner:u1"
             ]
    end

    test "group headers are selectable; runners are indented and under a disabled Ungrouped header" do
      opts = RunnerScope.options(@runners, [])

      assert %{disabled: false} = Enum.find(opts, &(&1.value == "group:app-api"))

      runner = Enum.find(opts, &(&1.value == "runner:r3"))
      assert runner.label =~ "api-iad-02"
      assert String.starts_with?(runner.label, " ")

      assert Enum.any?(opts, &(&1.label == "Ungrouped" and &1.disabled))
    end

    test "selecting a group disables its runners, tags them 'via group', leaves others alone" do
      opts = RunnerScope.options(@runners, ["group:edge-web"])

      assert Enum.find(opts, &(&1.value == "group:edge-web")).selected

      for value <- ["runner:r1", "runner:r2"] do
        option = Enum.find(opts, &(&1.value == value))
        assert option.disabled
        assert option.label =~ "via group"
        refute option.selected
      end

      # A runner in a DIFFERENT group stays enabled.
      refute Enum.find(opts, &(&1.value == "runner:r3")).disabled
    end

    test "an individually selected runner (no group selected) is marked selected" do
      opts = RunnerScope.options(@runners, ["runner:r3"])
      assert Enum.find(opts, &(&1.value == "runner:r3")).selected
    end
  end

  describe "parse/2" do
    test "splits into groups + runner_ids, allowlisting against the real runners (IL-15)" do
      parsed =
        RunnerScope.parse(
          ["group:app-api", "runner:r1", "group:ghost", "runner:from-another-account"],
          @runners
        )

      assert parsed == %{groups: ["app-api"], runner_ids: ["r1"]}
    end

    test "drops a runner already covered by a selected group" do
      parsed = RunnerScope.parse(["group:edge-web", "runner:r1", "runner:r3"], @runners)
      assert parsed == %{groups: ["edge-web"], runner_ids: ["r3"]}
    end

    test "empty selection parses to all-runners (both empty)" do
      assert RunnerScope.parse([], @runners) == %{groups: [], runner_ids: []}
    end
  end

  describe "to_values/2" do
    test "round-trips a persisted {groups, runner_ids} scope to selection strings" do
      assert RunnerScope.to_values(["edge-web"], ["r3"]) == ["group:edge-web", "runner:r3"]
    end
  end

  describe "runner_scope_select/1" do
    test "renders one grouped multi-select; a selected group's runners render disabled" do
      html =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          runners: @runners,
          selected: ["group:edge-web"]
        )

      assert html =~ ~s(<select)
      assert html =~ "multiple"
      assert html =~ "group:edge-web"
      # The "via group" tag only appears on a runner disabled because its group is picked.
      assert html =~ "via group"
    end
  end
end

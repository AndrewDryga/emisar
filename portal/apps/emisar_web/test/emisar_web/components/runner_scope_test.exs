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

    test "a selected ref the catalog no longer has is unavailable, not dropped" do
      tree = RunnerScope.tree(@runners, ["group:retired", "runner:gone", "group:edge-web"])

      assert tree.unavailable == [
               %{kind: :group, name: "retired", value: "group:retired"},
               %{kind: :runner, name: "gone", value: "runner:gone"}
             ]

      # A ref the catalog DOES account for stays in its own section.
      assert Enum.find(tree.groups, &(&1.name == "edge-web")).selected
    end

    test "an individually selected runner (no group selected) is selected, not covered" do
      tree = RunnerScope.tree(@runners, ["runner:r3"])
      runner = Enum.find(tree.groups, &(&1.name == "app-api")).runners |> hd()

      assert runner.selected
      refute runner.covered
    end
  end

  describe "selected_runner_ids/3" do
    test "all reaches every runner; restricted resolves groups and exact ids" do
      assert RunnerScope.selected_runner_ids(@runners, "all", []) == ["r1", "r2", "r3", "u1"]

      assert RunnerScope.selected_runner_ids(@runners, "restricted", ["group:edge-web"]) ==
               ["r1", "r2"]

      assert RunnerScope.selected_runner_ids(@runners, "restricted", ["runner:r3", "runner:u1"]) ==
               ["r3", "u1"]

      assert RunnerScope.selected_runner_ids(@runners, "restricted", []) == []
    end
  end

  describe "packs_in_scope/3" do
    @advertisements %{
      "linux-core" => ["r1", "r2", "r3"],
      "postgres" => ["r3"],
      "caddy" => ["r1"]
    }

    test "offers only the packs the selected runners carry, counting those runners" do
      assert RunnerScope.packs_in_scope(@advertisements, ["r1", "r2"]) == [
               %{id: "caddy", runner_count: 1},
               %{id: "linux-core", runner_count: 2}
             ]

      assert RunnerScope.packs_in_scope(@advertisements, ["r3"]) == [
               %{id: "linux-core", runner_count: 1},
               %{id: "postgres", runner_count: 1}
             ]

      assert RunnerScope.packs_in_scope(@advertisements, []) == []
    end

    test "a chosen pack stays listed even when nothing in scope carries it" do
      assert RunnerScope.packs_in_scope(@advertisements, ["r1"], ["pack:postgres"]) == [
               %{id: "caddy", runner_count: 1},
               %{id: "linux-core", runner_count: 1},
               %{id: "postgres", runner_count: 0}
             ]
    end
  end

  describe "pack_nodes/2" do
    test "sorts by pack id and keeps a selection nothing in scope carries" do
      packs = [
        %{id: "shell", runner_count: 2},
        %{id: "postgres", runner_count: 1},
        %{id: "retired", runner_count: 0}
      ]

      nodes = RunnerScope.pack_nodes(packs, ["pack:postgres", "pack:retired"])

      assert Enum.map(nodes.available, & &1.name) == ["shell", "postgres"]
      assert Enum.map(nodes.available, & &1.value) == ["pack:shell", "pack:postgres"]
      assert Enum.map(nodes.available, & &1.selected) == [false, true]
      assert Enum.map(nodes.available, & &1.runner_count) == [2, 1]
      assert Enum.map(nodes.unavailable, & &1.name) == ["retired"]
    end
  end

  describe "pack_scope_select/1" do
    test "renders one checkbox per pack with the runners carrying it" do
      html =
        render_component(&RunnerScope.pack_scope_select/1,
          name: "pack_scope[]",
          packs: [%{id: "postgres", runner_count: 1}, %{id: "shell", runner_count: 2}],
          selected: ["pack:postgres"]
        )

      assert html =~ ~s|name="pack_scope[]" value="pack:postgres"|
      assert html =~ ~s|name="pack_scope[]" value="pack:shell"|
      assert html =~ "1 runner"
      assert html =~ "2 runners"
    end

    test "the empty state names the reason the caller supplied" do
      html =
        render_component(&RunnerScope.pack_scope_select/1,
          name: "pack_scope[]",
          packs: [],
          selected: [],
          empty_message: "Choose runners first — the packs they carry appear here."
        )

      assert html =~ "Choose runners first"
    end

    test "a pack no runner in scope carries stays ticked and removable" do
      html =
        render_component(&RunnerScope.pack_scope_select/1,
          name: "pack_scope[]",
          packs: [],
          selected: ["pack:retired"]
        )

      assert html =~ "Unavailable"
      assert html =~ ~s(<input type="checkbox" checked)
      assert html =~ ~s|name="pack_scope[]" value="pack:retired">|
    end
  end

  describe "pack_access_field/1" do
    @field_advertisements %{"linux-core" => ["r1", "r2"], "postgres" => ["r3"]}

    test "renders nothing while the grant reaches no runner" do
      html =
        render_component(&RunnerScope.pack_access_field/1,
          runner_mode: "none",
          runners: @runners,
          advertisements: @field_advertisements,
          mode_name: "pack_access_mode",
          mode_value: "restricted",
          scope_name: "pack_scope[]",
          selected: []
        )

      refute html =~ "pack:linux-core"
      refute html =~ "All packs"
    end

    test "the pack list follows the runner selection" do
      edge_web =
        render_component(&RunnerScope.pack_access_field/1,
          runner_mode: "restricted",
          runner_scope: ["group:edge-web"],
          runners: @runners,
          advertisements: @field_advertisements,
          mode_name: "pack_access_mode",
          mode_value: "restricted",
          scope_name: "pack_scope[]",
          selected: []
        )

      assert edge_web =~ ~s|value="pack:linux-core"|
      refute edge_web =~ ~s|value="pack:postgres"|
      assert edge_web =~ "2 runners"

      everything =
        render_component(&RunnerScope.pack_access_field/1,
          runner_mode: "all",
          runners: @runners,
          advertisements: @field_advertisements,
          mode_name: "pack_access_mode",
          mode_value: "restricted",
          scope_name: "pack_scope[]",
          selected: []
        )

      assert everything =~ ~s|value="pack:linux-core"|
      assert everything =~ ~s|value="pack:postgres"|
    end

    test "an unresolved runner selection owns the empty state, not a pack failure" do
      html =
        render_component(&RunnerScope.pack_access_field/1,
          runner_mode: "restricted",
          runner_scope: [],
          runners: @runners,
          advertisements: @field_advertisements,
          mode_name: "pack_access_mode",
          mode_value: "restricted",
          scope_name: "pack_scope[]",
          selected: []
        )

      assert html =~ "Choose runners first"
    end

    test "the picker appears only once selected packs is chosen" do
      choice_only =
        render_component(&RunnerScope.pack_access_field/1,
          runner_mode: "all",
          runners: @runners,
          advertisements: @field_advertisements,
          mode_name: "pack_access_mode",
          mode_value: "all",
          scope_name: "pack_scope[]",
          selected: []
        )

      assert choice_only =~ "All packs"
      assert choice_only =~ "Selected packs"
      refute choice_only =~ ~s|value="pack:linux-core"|
    end
  end

  describe "to_pack_values/1" do
    test "round-trips a persisted pack scope to selection strings" do
      assert RunnerScope.to_pack_values(["postgres", "shell"]) == ["pack:postgres", "pack:shell"]
      assert RunnerScope.to_pack_values([]) == []
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

    test "an unavailable selection stays ticked and removable, even with an empty catalog" do
      html =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          runners: [],
          selected: ["group:retired"]
        )

      refute html =~ "No runners registered yet."
      assert html =~ "Unavailable"
      assert html =~ "unavailable"
      # Ticked, and the tag closes right after its value — so unlike a "via
      # group" runner it carries no `disabled`, and unticking it is possible.
      assert html =~ ~s(<input type="checkbox" checked)
      assert html =~ ~s|name="scope[]" value="group:retired">|
    end

    test "attached mode is one compact continuation with full-height option rows" do
      html =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          variant: :attached,
          runners: @runners,
          selected: []
        )

      assert html =~ "rounded-b-lg border border-t"
      assert html =~ "peer-focus-within/attached-panel:border-x-brand-500/70"
      assert html =~ "peer-focus-within/attached-panel:border-b-brand-500/70"
      refute html =~ "peer-focus-within/attached-panel:border-t-brand-500/70"
      assert html =~ "min-h-10"
      assert html =~ "text-xs transition-colors"
      assert html =~ "after:left-5"
      assert html =~ "after:top-[calc(50%+0.5rem)]"
      assert html =~ "before:bottom-5"
      assert html =~ "before:w-3"
      assert html =~ "before:bg-zinc-700/50"
      assert html =~ "after:bg-zinc-700/50"
      refute html =~ "before:w-5"
      refute html =~ "bg-zinc-700/70"
      assert html =~ "bg-white/[0.025]"
      assert html =~ "text-[11px]"
      refute html =~ "rounded-md bg-black/20"
      refute html =~ "ml-[1.4rem]"
      refute html =~ ">Selected runners<"
    end

    test "a dependency error stays quiet during change and appears after submit" do
      validating_form = runner_access_form(:validate)

      validating =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          variant: :attached,
          runners: @runners,
          selected: [],
          submit_error_field: validating_form[:runner_access_mode],
          submit_error_message: "Choose at least one runner."
        )

      refute validating =~ "Choose at least one runner."

      submitted_form = runner_access_form(:insert)

      submitted =
        render_component(&RunnerScope.runner_scope_select/1,
          name: "scope[]",
          variant: :attached,
          runners: @runners,
          selected: [],
          submit_error_field: submitted_form[:runner_access_mode],
          submit_error_message: "Choose at least one runner."
        )

      assert submitted =~ "Choose at least one runner."
    end
  end

  defp runner_access_form(action) do
    {%{runner_access_mode: "restricted"}, %{runner_access_mode: :string}}
    |> Ecto.Changeset.cast(%{runner_access_mode: "restricted"}, [:runner_access_mode])
    |> Ecto.Changeset.add_error(:runner_access_mode, "requires a runner")
    |> Map.put(:action, action)
    |> Phoenix.Component.to_form(as: "access")
  end
end

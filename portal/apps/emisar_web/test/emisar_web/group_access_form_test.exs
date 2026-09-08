defmodule EmisarWeb.GroupAccessFormTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Emisar.Accounts.RunnerAccess
  alias Emisar.SSO
  alias Emisar.SSO.GroupRunnerAccessMapping
  alias EmisarWeb.GroupAccessForm
  alias EmisarWeb.RunnerScope

  test "effective selections include defaults while submitted additions do not" do
    {:ok, default} = RunnerAccess.new(:restricted, ["database"], [], :restricted, ["postgres"])

    changeset =
      GroupRunnerAccessMapping.Changeset.form(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
        directory_group_id: Ecto.UUID.generate(),
        runner_access_mode: :none,
        pack_access_mode: :none
      })

    display = GroupAccessForm.presentation(default, changeset)
    assert display["runner_access_mode"] == "restricted"
    assert display["scope"] == ["group:database"]
    assert display["pack_scope"] == ["pack:postgres"]
    assert SSO.empty_group_access?(SSO.group_access_additions(default, %{}, display, []))

    extras =
      SSO.group_access_additions(
        default,
        %{
          "runner_access_mode" => "restricted",
          "scope" => ["group:database", "group:api"],
          "pack_access_mode" => "restricted",
          "pack_scope" => ["pack:postgres", "pack:shell"]
        },
        display,
        []
      )

    assert extras["scope"] == ["group:api"]
    assert extras["pack_scope"] == ["pack:shell"]
    refreshed = GroupAccessForm.presentation(RunnerAccess.all(), changeset)
    assert refreshed["runner_access_mode"] == "all"
    assert refreshed["pack_access_mode"] == "all"

    assert SSO.empty_group_access?(
             SSO.group_access_additions(RunnerAccess.all(), %{}, refreshed, [])
           )
  end

  test "No packs remains selected through an unrelated runner error" do
    changeset =
      GroupRunnerAccessMapping.Changeset.form(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
        directory_group_id: Ecto.UUID.generate(),
        runner_access_mode: :restricted,
        pack_access_mode: :none
      })

    refute changeset.valid?

    assert GroupAccessForm.presentation(RunnerAccess.none(), changeset)["pack_access_mode"] ==
             "none"
  end

  test "a stored pack-only grant stays visible and survives an unchanged save" do
    for {pack_mode, pack_scope} <- [{:all, []}, {:restricted, ["pack:postgres"]}] do
      changeset =
        GroupRunnerAccessMapping.Changeset.form(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
          directory_group_id: Ecto.UUID.generate(),
          runner_access_mode: :none,
          pack_access_mode: pack_mode,
          pack_scope: pack_scope
        })

      display = GroupAccessForm.presentation(RunnerAccess.none(), changeset)
      assert display["runner_access_mode"] == "none"
      assert display["pack_access_mode"] == to_string(pack_mode)
      assert display["pack_scope"] == pack_scope

      unchanged = SSO.group_access_additions(RunnerAccess.none(), %{}, display, [])
      refute SSO.empty_group_access?(unchanged)
      assert unchanged["pack_access_mode"] == to_string(pack_mode)
      assert unchanged["pack_scope"] == pack_scope

      removed =
        SSO.group_access_additions(
          RunnerAccess.none(),
          %{"pack_access_mode" => "none"},
          display,
          []
        )

      assert SSO.empty_group_access?(removed)
    end
  end

  test "inherited scope locks have unique tooltips and remain checked but disabled" do
    runners = for n <- 1..2, do: %{id: Ecto.UUID.generate(), group: "database", name: "db-#{n}"}

    html =
      render_component(&RunnerScope.runner_scope_select/1,
        name: "access[scope][]",
        runners: runners,
        selected: ["group:database"],
        locked: ["group:database"]
      )

    tree = LazyHTML.from_document(html)
    ids = tree |> LazyHTML.query("[phx-hook='Tooltip']") |> LazyHTML.attribute("id")
    assert length(ids) == 3
    assert length(Enum.uniq(ids)) == 3
    assert tree |> LazyHTML.query("input[checked][disabled]") |> Enum.count() == 3

    packs =
      render_component(&RunnerScope.pack_scope_select/1,
        name: "access[pack_scope][]",
        packs: [%{id: "postgres", runner_count: 2}],
        selected: ["pack:postgres"],
        locked: ["pack:postgres"]
      )

    assert packs
           |> LazyHTML.from_document()
           |> LazyHTML.query("input[value='pack:postgres'][checked][disabled]")
           |> Enum.count() == 1
  end
end

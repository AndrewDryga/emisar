defmodule Emisar.Accounts.ServiceAccountInputTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.{RunnerAccess, ServiceAccountInput}

  describe "changeset/2" do
    test "defaults to no runner access" do
      changeset = ServiceAccountInput.changeset(%{}, [])

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).display_name
      assert Ecto.Changeset.get_field(changeset, :runner_access_mode) == "none"
      assert Ecto.Changeset.get_field(changeset, :pack_access_mode) == "all"
      assert Ecto.Changeset.get_field(changeset, :runner_access) == RunnerAccess.none()
    end

    test "the name is required and at most 255 characters" do
      longest_name = %{"display_name" => String.duplicate("é", 255)}
      blank_name = %{"display_name" => " "}
      too_long_name = %{"display_name" => String.duplicate("é", 256)}

      assert ServiceAccountInput.changeset(longest_name, []).valid?

      blank = ServiceAccountInput.changeset(blank_name, [])
      assert "can't be blank" in errors_on(blank).display_name

      too_long = ServiceAccountInput.changeset(too_long_name, [])
      assert "should be at most 255 character(s)" in errors_on(too_long).display_name
    end

    test "a selection resolves for the Operator role every service account holds" do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      allowlist = %{groups: ["database"], runners: [database], packs: ["postgres"]}

      attrs = %{
        "display_name" => "Ryker",
        "runner_access_mode" => "restricted",
        "scope" => ["group:database", "runner:#{database.id}"],
        "pack_access_mode" => "restricted",
        "pack_scope" => ["pack:postgres"]
      }

      changeset = ServiceAccountInput.changeset(attrs, allowlist)

      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :runner_access) == %RunnerAccess{
               mode: :restricted,
               groups: ["database"],
               runner_ids: [],
               pack_mode: :restricted,
               pack_ids: ["postgres"]
             }

      assert Ecto.Changeset.get_field(changeset, :scope) == ["group:database"]
      assert Ecto.Changeset.get_field(changeset, :pack_scope) == ["pack:postgres"]
    end
  end
end

defmodule Emisar.Accounts.Account.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.Account
  alias Emisar.Fixtures

  describe "create/1" do
    test "is valid with default attrs" do
      assert changeset().valid?
    end

    test "validates account name length (1..80 inclusive)" do
      assert changeset(name: "a").valid?
      assert changeset(name: String.duplicate("a", 80)).valid?

      assert "can't be blank" in errors_on(changeset(name: "")).name

      too_long = changeset(name: String.duplicate("a", 81))
      assert "should be at most 80 character(s)" in errors_on(too_long).name
    end

    test "validates slug format" do
      assert changeset(slug: "valid-slug-1").valid?

      assert "can't be blank" in errors_on(changeset(slug: "")).slug

      expected_error =
        "must be lowercase letters/numbers/hyphens, start with a letter, 3-64 chars"

      for bad <- ["x", "UPPER", "1lead", "-lead", "has space"] do
        assert expected_error in errors_on(changeset(slug: bad)).slug
      end
    end
  end

  defp changeset(overrides \\ %{}) do
    Account.Changeset.create(Fixtures.Accounts.account_attrs(overrides))
  end
end

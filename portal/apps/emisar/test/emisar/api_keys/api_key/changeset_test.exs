defmodule Emisar.ApiKeys.ApiKey.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.ApiKeys.ApiKey

  describe "create/6" do
    test "requires the minting membership" do
      changeset =
        ApiKey.Changeset.create(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          nil,
          "emk-test-key",
          <<0>>,
          %{name: "Agent"}
        )

      assert "can't be blank" in errors_on(changeset).created_by_membership_id
    end
  end

  describe "mint_quick/5" do
    test "requires the minting membership" do
      changeset =
        ApiKey.Changeset.mint_quick(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          nil,
          "emk-test-key",
          <<0>>
        )

      assert "can't be blank" in errors_on(changeset).created_by_membership_id
    end
  end
end

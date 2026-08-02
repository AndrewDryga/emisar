defmodule Emisar.ApiKeys.ApiKey.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.ApiKeys.ApiKey

  describe "form/1" do
    test "casts the create form's browser params, reading the expiry as UTC" do
      params = %{
        "name" => "Agent",
        "description" => "laptop bridge",
        "expires_at" => "2099-12-25T10:30"
      }

      changeset = ApiKey.Changeset.form(params)

      assert changeset.valid?

      assert changeset.changes == %{
               name: "Agent",
               description: "laptop bridge",
               expires_at: ~U[2099-12-25 10:30:00.000000Z]
             }
    end

    test "blank optional values normalize to absent" do
      params = %{"name" => "Agent", "description" => "   ", "expires_at" => ""}

      changeset = ApiKey.Changeset.form(params)

      assert changeset.valid?
      assert changeset.changes == %{name: "Agent"}
    end

    test "an already-typed expiry passes through untouched" do
      expires_at = ~U[2099-12-25 10:30:00.000000Z]

      changeset = ApiKey.Changeset.form(%{name: "Agent", expires_at: expires_at})

      assert changeset.valid?
      assert changeset.changes == %{name: "Agent", expires_at: expires_at}
    end

    test "a full timestamp still casts — only the browser's minute stamp is rewritten" do
      params = %{"name" => "Agent", "expires_at" => "2099-12-25T10:30:45Z"}

      changeset = ApiKey.Changeset.form(params)

      assert changeset.valid?

      assert changeset.changes == %{
               name: "Agent",
               expires_at: ~U[2099-12-25 10:30:45.000000Z]
             }
    end

    # A malformed expiry must reach Ecto as-is: swallowing it would hand the
    # operator the silent 30-day default instead of the date they typed.
    test "a malformed expiry is a cast error, never a silent nil" do
      changeset = ApiKey.Changeset.form(%{"name" => "Agent", "expires_at" => "25/12/2030"})

      assert "is invalid" in errors_on(changeset).expires_at
    end

    test "an expiry at or before now must be in the future" do
      now = DateTime.utc_now()
      at_now = ApiKey.Changeset.form(%{name: "Agent", expires_at: now})
      past = ApiKey.Changeset.form(%{name: "Agent", expires_at: DateTime.add(now, -60, :second)})

      assert "must be in the future" in errors_on(at_now).expires_at
      assert "must be in the future" in errors_on(past).expires_at
    end
  end

  describe "create/6" do
    test "casts the browser's params exactly as form/1 does" do
      account_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()
      membership_id = Ecto.UUID.generate()
      lineage_id = Ecto.UUID.generate()
      attrs = %{"name" => "Agent", "description" => "  ", "expires_at" => "2099-12-25T10:30"}

      changeset =
        ApiKey.Changeset.create(
          account_id,
          user_id,
          membership_id,
          "emk-test-key",
          <<0>>,
          attrs,
          credential_lineage_id: lineage_id
        )

      assert changeset.valid?

      assert changeset.changes == %{
               name: "Agent",
               expires_at: ~U[2099-12-25 10:30:00.000000Z],
               account_id: account_id,
               created_by_id: user_id,
               created_by_membership_id: membership_id,
               credential_lineage_id: lineage_id,
               key_prefix: "emk-test-key",
               key_hash: <<0>>
             }
    end

    test "an expiry at or before now is refused" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      changeset =
        ApiKey.Changeset.create(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          "emk-test-key",
          <<0>>,
          %{name: "Agent", expires_at: past}
        )

      refute changeset.valid?
      assert "must be in the future" in errors_on(changeset).expires_at
    end

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

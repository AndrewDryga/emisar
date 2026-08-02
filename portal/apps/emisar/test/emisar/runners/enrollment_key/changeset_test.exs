defmodule Emisar.Runners.EnrollmentKey.ChangesetTest do
  use Emisar.DataCase, async: true
  alias Emisar.Runners.EnrollmentKey

  describe "form/1" do
    test "casts the create form's browser params, reading the expiry as UTC" do
      params = %{
        "description" => "prod web tier",
        "reusable" => "true",
        "max_uses" => "5",
        "expires_at" => "2099-12-25T10:30"
      }

      changeset = EnrollmentKey.Changeset.form(params)

      assert changeset.valid?

      assert changeset.changes == %{
               description: "prod web tier",
               reusable: true,
               max_uses: 5,
               expires_at: ~U[2099-12-25 10:30:00.000000Z]
             }
    end

    test "blank optional values normalize to absent" do
      params = %{"description" => "   ", "reusable" => "true", "expires_at" => ""}

      changeset = EnrollmentKey.Changeset.form(params)

      assert changeset.valid?
      assert changeset.changes == %{reusable: true}
    end

    test "an already-typed expiry passes through untouched" do
      expires_at = ~U[2099-12-25 10:30:00.000000Z]

      changeset = EnrollmentKey.Changeset.form(%{description: "typed", expires_at: expires_at})

      assert changeset.valid?
      assert changeset.changes == %{description: "typed", expires_at: expires_at}
    end

    test "a full timestamp still casts — only the browser's minute stamp is rewritten" do
      changeset = EnrollmentKey.Changeset.form(%{"expires_at" => "2099-12-25T10:30:45Z"})

      assert changeset.valid?
      assert changeset.changes == %{expires_at: ~U[2099-12-25 10:30:45.000000Z]}
    end

    # A malformed expiry must reach Ecto as-is: swallowing it would mint the
    # never-expiring key the operator was trying to put a date on.
    test "a malformed expiry is a cast error, never a silent nil" do
      changeset = EnrollmentKey.Changeset.form(%{"expires_at" => "25/12/2030"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).expires_at
    end

    test "a description over 200 characters is refused" do
      changeset = EnrollmentKey.Changeset.form(%{"description" => String.duplicate("x", 201)})

      refute changeset.valid?
      assert "should be at most 200 character(s)" in errors_on(changeset).description
    end

    test "a reusable key keeps a positive max_uses" do
      changeset = EnrollmentKey.Changeset.form(%{"reusable" => "true", "max_uses" => "5"})

      assert changeset.valid?
      assert changeset.changes == %{reusable: true, max_uses: 5}
    end

    test "a single-use key drops max_uses — the cap never applies" do
      changeset = EnrollmentKey.Changeset.form(%{"reusable" => "false", "max_uses" => "5"})

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "max_uses 0 mints a key that is dead on arrival" do
      changeset = EnrollmentKey.Changeset.form(%{"reusable" => "true", "max_uses" => "0"})

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).max_uses
    end

    test "a malformed max_uses stays an addressable error on a single-use key" do
      changeset = EnrollmentKey.Changeset.form(%{"reusable" => "false", "max_uses" => "many"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).max_uses
    end
  end

  describe "create/5" do
    test "casts the browser's params exactly as form/1 does" do
      account_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      params = %{
        "description" => "  ",
        "reusable" => "true",
        "max_uses" => "5",
        "expires_at" => "2099-12-25T10:30"
      }

      changeset =
        EnrollmentKey.Changeset.create(account_id, user_id, "emkey-enroll-test", <<0>>, params)

      assert changeset.valid?

      assert changeset.changes == %{
               reusable: true,
               max_uses: 5,
               expires_at: ~U[2099-12-25 10:30:00.000000Z],
               account_id: account_id,
               created_by_id: user_id,
               key_prefix: "emkey-enroll-test",
               key_hash: <<0>>
             }
    end

    test "a single-use key drops max_uses at the write path too" do
      attrs = %{description: "one shot", reusable: false, max_uses: 5}

      changeset =
        EnrollmentKey.Changeset.create(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          "emkey-enroll-test",
          <<0>>,
          attrs
        )

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :max_uses)
    end

    test "a malformed expiry is refused, not dropped" do
      changeset =
        EnrollmentKey.Changeset.create(
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          "emkey-enroll-test",
          <<0>>,
          %{"expires_at" => "25/12/2030"}
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).expires_at
    end

    test "requires the owning account" do
      changeset =
        EnrollmentKey.Changeset.create(
          nil,
          Ecto.UUID.generate(),
          "emkey-enroll-test",
          <<0>>,
          %{description: "orphan"}
        )

      assert "can't be blank" in errors_on(changeset).account_id
    end
  end
end

defmodule Emisar.Accounts.InvitationInputTest do
  use Emisar.DataCase, async: true
  alias Emisar.Accounts.{InvitationInput, RunnerAccess}
  alias Emisar.Fixtures

  describe "changeset/2" do
    test "defaults to an operator with no runner access" do
      changeset = InvitationInput.changeset(%{}, [])

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).email
      assert Ecto.Changeset.get_field(changeset, :role) == "operator"
      assert Ecto.Changeset.get_field(changeset, :runner_access_mode) == "none"
      assert Ecto.Changeset.get_field(changeset, :runner_access) == RunnerAccess.none()
    end

    test "trims the email and keeps the typed casing" do
      attrs = Fixtures.Accounts.invitation_attrs(email: "  HELLO@Example.Test  ")
      changeset = InvitationInput.changeset(attrs, [])

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :email) == "HELLO@Example.Test"
    end

    test "an address without an @ sign or with a space is a field error" do
      for email <- ["nope", "b ob@x.com"] do
        attrs = Fixtures.Accounts.invitation_attrs(email: email)
        changeset = InvitationInput.changeset(attrs, [])

        assert "must have the @ sign and no spaces" in errors_on(changeset).email
      end
    end

    test "the role must be one of the canonical Auth roles" do
      for role <- Enum.map(Emisar.Auth.roles(), &Atom.to_string/1) do
        attrs = Fixtures.Accounts.invitation_attrs(role: role)
        assert InvitationInput.changeset(attrs, []).valid?
      end

      attrs = Fixtures.Accounts.invitation_attrs(role: "superadmin")
      assert "is invalid" in errors_on(InvitationInput.changeset(attrs, [])).role
    end

    test "an unknown runner access mode is a field error" do
      attrs = Fixtures.Accounts.invitation_attrs(runner_access_mode: "everything")
      changeset = InvitationInput.changeset(attrs, [])

      assert "is invalid" in errors_on(changeset).runner_access_mode
    end

    test "a selected scope canonicalizes against the account's runners" do
      database = %{id: Ecto.UUID.generate(), group: "database"}
      web = %{id: Ecto.UUID.generate(), group: "web"}

      attrs =
        Fixtures.Accounts.invitation_attrs(
          runner_access_mode: "restricted",
          scope: ["runner:#{web.id}", "group:database", "runner:#{database.id}"]
        )

      changeset = InvitationInput.changeset(attrs, [database, web])

      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :runner_access) == %RunnerAccess{
               mode: :restricted,
               groups: ["database"],
               runner_ids: [web.id]
             }

      assert Ecto.Changeset.get_field(changeset, :scope) ==
               ["group:database", "runner:#{web.id}"]
    end

    test "an empty or unallowlisted selection is a runner_access_mode error" do
      database = %{id: Ecto.UUID.generate(), group: "database"}

      for scope <- [[], ["group:staging"], ["runner:#{Ecto.UUID.generate()}"], ["crafted"]] do
        attrs =
          Fixtures.Accounts.invitation_attrs(runner_access_mode: "restricted", scope: scope)

        changeset = InvitationInput.changeset(attrs, [database])

        assert "requires at least one runner group or runner" in errors_on(changeset).runner_access_mode
      end
    end
  end
end
